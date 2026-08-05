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
  fqdn before this release ran, so deleting it restores exactly the prior world.
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
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Networking

  @impl true
  def run(step, ctx) do
    deployment = Deployments.get_deployment!(target_id(step, ctx))

    case deployment.domain do
      domain when is_binary(domain) and domain != "" ->
        # Read BEFORE the sync, so the handle records whether this step is the one
        # that brought the row into existence. `compensate/2` refuses to delete
        # anything it did not create.
        existed? = match?({:ok, _}, Networking.get_domain_by_fqdn(domain))

        Deployments.sync_domain_records(deployment)

        case Networking.get_domain_by_fqdn(domain) do
          {:ok, row} ->
            {:ok,
             %{
               "fqdn" => row.fqdn,
               "domain_id" => row.id,
               "deployment_id" => deployment.id,
               "created" => not existed?,
               "reclaimed" => existed?
             }}

          {:error, :not_found} ->
            {:error, {:sync_domain_failed, deployment.id, :domain_row_not_persisted}}
        end

      _ ->
        # No name to answer to: still retire whatever this deployment used to hold.
        Deployments.sync_domain_records(deployment)
        {:ok, %{"fqdn" => nil, "deployment_id" => deployment.id, "created" => false}}
    end
  end

  @impl true
  def compensate(step, _ctx) do
    handle = step.resource_handle || %{}

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

  defp target_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") || ctx.deployment.id
  end
end
