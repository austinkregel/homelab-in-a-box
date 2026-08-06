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

  ## `compensate/2`: exactly the records THIS step wrote

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

    case Networking.ensure_deployment_dns_records(deployment, Deployments.detect_ip_config()) do
      {:ok, results} ->
        {written, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

        if failed == [] do
          log_written(deployment, written)

          handle = %{
            "deployment_id" => deployment.id,
            "fqdn" => deployment.domain,
            "record_ids" => Enum.map(written, fn {:ok, record} -> record.id end),
            "record_count" => length(written)
          }

          # Durable before the runner's completion CAS. See the moduledoc: the returned
          # handle is exactly what a crash between the side effect and that CAS
          # discards, and without the ids compensation has nothing to scope to.
          _ = Releases.record_step_handle(step, handle)

          {:ok, handle}
        else
          reason = Enum.map(failed, fn {:error, r} -> r end)
          activity_error(deployment, reason)
          {:error, {:publish_dns_failed, deployment.id, reason}}
        end

      {:error, reason} ->
        activity_error(deployment, reason)
        {:error, {:publish_dns_failed, deployment.id, reason}}
    end
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
