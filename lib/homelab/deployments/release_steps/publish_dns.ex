defmodule Homelab.Deployments.ReleaseSteps.PublishDns do
  @moduledoc """
  Publishes the deployment's A records — locally as `DnsRecord` rows and outward to
  every configured DNS provider. The saga equivalent of `do_deploy/1`'s
  `create_dns_records/1`, which the release path never ran: a saga-deployed app got a
  Traefik route and no name pointing at it.

  The address comes from `Deployments.detect_ip_config/0` — the same host-LAN-IP guess
  the imperative path used, shared rather than copied so the two cannot drift.

  ## Why this one DOES fail the release

  Unlike `EnsureIngressProxy`, a failure here is local and specific: `{:error, _}` from
  `ensure_deployment_dns_records/2` means the zone or the record row could not be
  written. Provider-side push failures do NOT surface here (they are recorded on the
  row as `last_sync_error`), so an install with no DNS provider still succeeds. A
  release that reports `:running` for a routed app whose name resolves nowhere is the
  exact "success for durable work that did not happen" this step exists to prevent.

  ## `compensate/2`: exactly the records THIS step CREATED

  A DNS A record is the one artifact in this plan that is externally visible and
  **cached by resolvers** — leaving it behind after a rollback points the world at a
  container that no longer exists, for as long as the TTL says. So it is undone.

  Scoped to the record ids `run/2` recorded, not to the deployment. `run/2` UPSERTS, so
  it is not necessarily the row's author, and `managed: true` cannot stand in for
  authorship: `ensure_deployment_dns_records/2` sets it unconditionally on every record
  of every release, to separate homelab-written rows from operator-hand-made ones.
  Compensating by `deployment_id` therefore deleted records earlier releases created —
  most visibly after a domain move, where rolling back the release that published the
  NEW name also destroyed the OLD name the deployment is still answering to and the
  world is still cached against.

  Recording the ids is necessary and was not sufficient. `upsert_dns_record/2` takes
  over whatever row already resolves the name — any writer's — so the SAME-name case
  slipped through the id scoping: release 2 republishes a name release 1 published,
  records those ids as its own, and its rollback deletes them at the provider. The
  deployment reverts to the container it was already running, and its name resolves
  nowhere. So `run/2` reads the rows that already resolve the name BEFORE it upserts and
  subtracts them: what it took over is recorded as `"took_over_record_ids"` for the
  account, and only what it CREATED goes into `"record_ids"`.

  This is the rule `SyncDomain` already applies to the `Domain` row — delete a row this
  step created, leave one it only reclaimed — and the two now agree. It is what makes an
  adoption rollback safe: an adoption that rolls back must leave the ORIGINAL serving,
  and deleting the record the original is reached at would make the rollback worse than
  never adopting.

  The deletion goes through `Networking.delete_dns_records_for/2`, which pushes to the
  provider FIRST and keeps the local row if that push is refused: dropping the row
  drops the `provider_record_id` that addresses the live record, leaving an orphan
  nothing can ever clean up. A refusal is RETURNED, not logged and forgotten — a
  compensation that could not reach the provider has undone nothing externally, and
  reporting `:ok` there is what turns a rollback into that orphan.

  It also re-checks that each record still belongs to this deployment: between the
  write and the undo one may legitimately have been re-pointed elsewhere.

  Idempotent: a second call finds the ids already gone and deletes nothing.

  ## Why the ids are persisted mid-step

  `ReleaseRunner` stores a returned handle only at the completion compare-and-set, so a
  node that dies between the upsert and that CAS would lose the ids and leave
  compensation with nothing to scope to. They go onto the step row through
  `Releases.record_step_handle/2` as soon as they are known — the same durability
  `SyncDomain` needs for its provenance, and for the same reason.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Releases
  alias Homelab.Networking
  alias Homelab.Services.ActivityLog

  @impl true
  def run(step, ctx) do
    deployment = Deployments.get_deployment!(target_id(step, ctx))

    # Read BEFORE the upsert: the rows that already resolve this name are the ones
    # `ensure_deployment_dns_records/2` is about to take over rather than create, and
    # after it has run there is nothing left to tell them apart by. See the moduledoc.
    took_over = preexisting_ids(deployment)

    case Networking.ensure_deployment_dns_records(deployment, Deployments.detect_ip_config()) do
      {:ok, results} ->
        {written, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

        # Recorded BEFORE the outcome is decided, because a partial write is still a
        # write. With several hostnames per deployment, "the primary's record went in and
        # an alias's zone could not be created" is an ordinary failure — and returning
        # the error without recording left those live rows owned by nothing: compensation
        # read `record_ids: nil` and deleted none of them, and the retry saw them as
        # pre-existing and filed them under `took_over` forever.
        #
        # The step still FAILS below. What it must not do is fail having forgotten what
        # it did.
        handle = build_handle(step, deployment, written, took_over)
        _ = Releases.record_step_handle(step, handle)

        if failed == [] do
          log_written(deployment, written)
          {:ok, handle}
        else
          reason = Enum.map(failed, fn {:error, r} -> r end)
          activity_error(deployment, reason)
          {:error, {:publish_dns_failed, deployment.id, reason}}
        end

      # Nothing was written, so there is nothing to record and nothing to undo.
      {:error, reason} ->
        activity_error(deployment, reason)
        {:error, {:publish_dns_failed, deployment.id, reason}}
    end
  end

  defp build_handle(step, deployment, written, took_over) do
    %{
      "deployment_id" => deployment.id,
      "fqdn" => deployment.domain,
      # UNION with whatever a previous attempt of this same step recorded, not a
      # replacement. A reclaimed step re-runs from scratch and can publish a
      # different name than it did the first time — the operator moved the domain
      # in between, and `ensure_deployment_dns_records/2` writes the current name
      # without retiring the previous one. Both sets are this step's to undo.
      # (`record_count` stays this attempt's count: it describes what was just
      # written, which is what the Activity line reports.)
      #
      # Minus the rows that already existed. Those were taken over, not created,
      # and are not this step's to delete — see the moduledoc. The union above is
      # what keeps that correct across a reclaim: a row THIS step created on an
      # earlier attempt is "pre-existing" by the time the re-run reads, and is
      # carried back in from the handle rather than re-derived.
      "record_ids" => Enum.uniq(recorded_ids(step) ++ (written_ids(written) -- took_over)),
      "took_over_record_ids" => took_over,
      "record_count" => length(written)
    }
  end

  @impl true
  def compensate(step, ctx) do
    handle = step.resource_handle || %{}
    deployment_id = Map.get(handle, "deployment_id") || ctx.deployment.id

    case Map.get(handle, "record_ids") do
      # Nothing recorded means nothing to undo. NOT a licence to fall back to
      # "everything this deployment has" — that fallback is the defect: it deletes rows
      # written by other releases, which this step neither created nor can restore.
      ids when ids in [nil, []] ->
        :ok

      ids when is_list(ids) ->
        case Networking.delete_dns_records_for(ids, deployment_id) do
          :ok ->
            :ok

          {:error, reason} ->
            activity_delete_error(deployment_id, reason)
            {:error, {:publish_dns_compensation_failed, deployment_id, reason}}
        end
    end
  end

  defp written_ids(written), do: Enum.map(written, fn {:ok, record} -> record.id end)

  # Across EVERY name this step is about to publish, not just the primary domain.
  # `ensure_deployment_dns_records/2` now also writes an A record for each additional
  # domain, and a record it merely took over on an alias is no more this step's to delete
  # than one on the primary -- rolling back would strip the name off whatever published
  # it, exactly the failure the moduledoc describes one host over.
  defp preexisting_ids(deployment) do
    deployment
    |> Networking.deployment_hostnames()
    |> Enum.flat_map(&Networking.list_dns_records_for_fqdn/1)
    |> Enum.map(& &1.id)
    |> Enum.uniq()
  end

  defp recorded_ids(step) do
    case (step.resource_handle || %{})["record_ids"] do
      ids when is_list(ids) -> ids
      _ -> []
    end
  end

  defp log_written(_deployment, []), do: :ok

  defp log_written(deployment, written) do
    ActivityLog.info(
      "dns",
      "Created #{length(written)} DNS record(s) for #{deployment.domain}",
      %{deployment_id: deployment.id}
    )
  end

  defp activity_delete_error(deployment_id, reason) do
    ActivityLog.error(
      "dns",
      "Failed to delete DNS records during rollback: #{inspect(reason)}",
      %{deployment_id: deployment_id}
    )
  end

  defp activity_error(deployment, reason) do
    ActivityLog.error(
      "dns",
      "Failed to create DNS records for #{deployment.domain}: #{inspect(reason)}",
      %{deployment_id: deployment.id}
    )
  end

  defp target_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") || ctx.deployment.id
  end
end
