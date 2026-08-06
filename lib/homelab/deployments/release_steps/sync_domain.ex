defmodule Homelab.Deployments.ReleaseSteps.SyncDomain do
  @moduledoc """
  Brings the local `Domain` rows in line with the name the deployment is served at:
  retires rows for names it no longer answers to, and creates or reclaims the row for
  its current one. The saga equivalent of `do_deploy/1`'s `post_deploy_hooks/1` →
  `Deployments.sync_domain_records/1`, which the release path did not run at all — so
  a saga-deployed app never appeared on the Domains page, had no `exposure_mode` row
  for the access layer to read, and no TLS state to track.

  ## Why it runs AFTER the app's `:await_health`, not first

  A `Domain` row is an assertion that this name is served. Writing it before the
  workload exists asserts something untrue for the whole length of the deploy, and a
  first deploy that fails would leave that assertion behind permanently.

  ## Why `run/2` re-reads the row instead of trusting `sync_domain_records/1`

  `sync_domain_records/1` returns `:ok` whether or not the insert succeeded — it
  logs the failure and moves on, which is fine for a fire-and-forget hook and not
  fine for a saga step. The read-back is what turns a silently-dropped row into a
  failed step.

  ## `compensate/2`: deletes only a row this step CREATED

  The narrow rule matters. `"created" => true` means no `Domain` row existed for this
  fqdn before this release ran, so deleting it takes the row back out.
  `"reclaimed" => true` means a row was already there — pointed at some other
  deployment, or left by an earlier release — and deleting it would destroy state this
  release never owned, including its TLS status and zone link.

  The reason to compensate at all, rather than leaning on "the row is derived from
  `deployments.domain`, which survives rollback, and `sync_domain_records/1` is
  convergent": `fqdn` carries a UNIQUE constraint. A first deploy that rolls back
  otherwise strands a globally-unique claim on a name that has never resolved, and
  `retire_stale_domains/2` will not clear it — that only sweeps rows belonging to the
  *same* deployment. Another deployment attempting that name later is refused by the
  database with no visible cause.

  Reachability is a separate concern and is not undone here; `PublishIngress.compensate/2`
  owns that.

  ## What compensation does NOT undo — the retirement

  `sync_domain_records/1`'s FIRST act is `retire_stale_domains/2`, which deletes this
  deployment's `Domain` rows for every *other* name, exposure mode, TLS status and zone
  link included. Compensation does not bring them back, so it does not restore the
  prior world and this moduledoc no longer says it does. That is a decision, not an
  omission:

    * Re-inserting a retired row re-claims a globally **UNIQUE** `fqdn` on behalf of a
      deployment that no longer answers to it. That is precisely the stranded-claim
      failure the paragraph above gives as the reason compensation exists at all —
      restoring here would reintroduce it from the other direction, and could block a
      deployment that legitimately took the name in the meantime.
    * The rows are DERIVED from `deployments.domain`, and a rollback does not change
      that field — the operator's edit committed before the release was planned. A
      restored row would contradict the deployment's own domain, and the next
      convergence (any redeploy, any config save) would retire it again immediately. It
      would be a momentary restoration of an inconsistency, not of the prior world.
    * What is genuinely lost is TLS state for a name the deployment is not served at.
      The certificate itself lives in the proxy's ACME store, not in this row.

  So the retirement is **recorded** instead: `"retired" => [%{"fqdn", "exposure_mode",
  "tls_status"}]` on the handle, in both branches, persisted before the mutation like
  the provenance below (the re-run cannot re-derive it — the first attempt already
  deleted the rows). A rollback leaves a legible account of what it could not undo,
  which is the part that was missing.

  ## Provenance has to be durable, not merely returned

  The created-vs-reclaimed answer is learned by observing the world BEFORE this step
  changes it, and the runner persists a returned handle only at the completion
  compare-and-set. A node that dies in between leaves the row written and the
  provenance lost — `reclaim_running_steps/1` puts the step back to `:pending` with an
  empty handle, the re-run sees a row that exists because WE wrote it, and concludes it
  was reclaimed. So the answer is written to the step row through
  `Releases.record_step_handle/2` before `sync_domain_records/1` runs, and a handle
  already claiming `"created"` always wins over a fresh read.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Releases
  alias Homelab.Networking

  @impl true
  def run(step, ctx) do
    deployment = Deployments.get_deployment!(target_id(step, ctx))

    case deployment.domain do
      domain when is_binary(domain) and domain != "" ->
        # Read BEFORE the sync, so the handle records whether this step is the one that
        # brought the row into existence. `compensate/2` refuses to delete anything it
        # did not create.
        #
        # A handle already carrying `"created" => true` WINS over that read. This step
        # can be re-run from scratch — a node that dies after the row is written but
        # before the runner's completion CAS has `reclaim_running_steps/1` put the step
        # back to `:pending` — and on the re-run the row exists because WE wrote it. Re-
        # deriving provenance there flips it to "reclaimed" and compensation then
        # refuses to delete a row this release created, stranding the unique `fqdn`
        # claim this step exists to protect.
        existed? = match?({:ok, _}, Networking.get_domain_by_fqdn(domain))
        created? = handle(step)["created"] == true or not existed?
        retired = retiring(step, deployment, domain)

        # Persisted BEFORE the mutation, and this is the load-bearing half. Returning
        # the provenance in the handle is not enough: the returned handle is exactly
        # what a crash between the side effect and the CAS discards. See
        # `Releases.record_step_handle/2`.
        _ =
          Releases.record_step_handle(step, %{
            "created" => created?,
            "reclaimed" => not created?,
            "retired" => retired,
            "fqdn" => domain,
            "deployment_id" => deployment.id
          })

        Deployments.sync_domain_records(deployment)

        case Networking.get_domain_by_fqdn(domain) do
          {:ok, row} ->
            {:ok,
             %{
               "fqdn" => row.fqdn,
               "domain_id" => row.id,
               "deployment_id" => deployment.id,
               "created" => created?,
               "reclaimed" => not created?,
               "retired" => retired
             }}

          {:error, :not_found} ->
            {:error, {:sync_domain_failed, deployment.id, :domain_row_not_persisted}}
        end

      _ ->
        # No name to answer to: EVERY row this deployment holds is stale, so this branch
        # is pure retirement — the one that destroys most and used to record nothing.
        retired = retiring(step, deployment, nil)

        handle = %{
          "fqdn" => nil,
          "deployment_id" => deployment.id,
          "created" => false,
          "retired" => retired
        }

        _ = Releases.record_step_handle(step, handle)

        Deployments.sync_domain_records(deployment)

        {:ok, handle}
    end
  end

  # The rows `retire_stale_domains/2` is about to delete, captured before it runs.
  #
  # Not restored on compensation — see the moduledoc for why — but recorded, so a
  # rollback leaves an account of the exposure and TLS state it could not put back. A
  # handle that already carries the list WINS over a fresh read, exactly as `"created"`
  # does and for the same reason: after a reclaimed re-run the rows are already gone, so
  # re-deriving would silently replace the account with an empty one.
  defp retiring(step, deployment, current_fqdn) do
    case handle(step)["retired"] do
      recorded when is_list(recorded) and recorded != [] ->
        recorded

      _ ->
        deployment.id
        |> Networking.list_domains_for_deployment()
        |> Enum.reject(&(&1.fqdn == current_fqdn))
        |> Enum.map(
          &%{
            "fqdn" => &1.fqdn,
            "exposure_mode" => to_string(&1.exposure_mode),
            "tls_status" => to_string(&1.tls_status)
          }
        )
    end
  end

  @impl true
  def compensate(step, _ctx) do
    handle = handle(step)

    with true <- handle["created"] == true,
         fqdn when is_binary(fqdn) <- handle["fqdn"],
         {:ok, row} <- Networking.get_domain_by_fqdn(fqdn) do
      # Only if it is still OUR row. Between the deploy and the rollback another
      # deployment may legitimately have taken the name over.
      if row.deployment_id == handle["deployment_id"] do
        _ = Networking.delete_domain(row)
      end

      :ok
    else
      # Not created by us, already gone, or no fqdn recorded — nothing to undo.
      _ -> :ok
    end
  end

  defp handle(step), do: step.resource_handle || %{}

  defp target_id(step, ctx) do
    Map.get(handle(step), "deployment_id") || ctx.deployment.id
  end
end
