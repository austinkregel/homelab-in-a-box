defmodule Homelab.Deployments.ReleaseSteps.DeployContainer do
  @moduledoc """
  Deploys a deployment's container via the orchestrator. Registered for both
  `:dependency_container` (the companion, identified by
  `resource_handle["deployment_id"]`) and `:app_container` (the release's own
  `ctx.deployment`).

  Generate-once credentials for the deployment are merged into the spec's env at
  deploy time, so the same values provisioned earlier reach the container. The
  resulting container id is stored on `deployments.external_id` (where the
  reconciler's steady-state path already expects it) and in the step handle.

  `compensate/2` undeploys the container and clears the row's `external_id`, so a
  rolled-back release leaves no orphan. Idempotent: undeploy of a missing
  container is a no-op.

  Both failure branches mark the deployment `:failed`. That is not cosmetic: a row
  left `:pending` with no `external_id` is a row the reconciler skips forever
  (`converge_one/2` returns on `external_id: nil`), so a saga deploy that failed to
  build a spec or failed at the orchestrator would sit "pending" with no convergence
  path and no error on the page.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.SpecBuilder

  @deployable_from [:pending, :deploying, :failed, :stopped]

  @impl true
  def run(step, ctx) do
    deployment = load_target(step, ctx)

    with {:ok, spec} <- SpecBuilder.build(deployment) do
      # Secrets are merged by `SpecBuilder.build_env/5` now, so every deploy path gets
      # them — including `recreate_deployment/1`, which is what a config save runs and
      # which used to drop them because this merge lived here rather than at the seam.
      case orchestrator().deploy(spec) do
        {:ok, external_id} ->
          Deployments.transition_status(deployment, :deploying, @deployable_from,
            external_id: external_id
          )

          record_netns_parent(deployment, spec)

          Logger.info("[deploy_container] deployed #{deployment.id} -> #{external_id}")

          {:ok,
           %{
             "kind" => "container",
             "external_id" => external_id,
             "deployment_id" => deployment.id
           }}

        {:error, reason} ->
          mark_failed(deployment, reason)
          {:error, {:deploy_failed, deployment.id, reason}}
      end
    else
      # `SpecBuilder.build/1` failed. This `with` had no `else`, so the error fell
      # straight through to the runner and the deployment row was left `:pending` —
      # and `Reconciler.converge_one/2` returns immediately for a row with no
      # `external_id`, so nothing ever moved it again. `do_deploy/1` set `:failed`
      # here; losing that on the saga path is how a deployment becomes permanently
      # invisible instead of visibly broken.
      {:error, reason} ->
        mark_failed(load_target(step, ctx), reason)
        {:error, {:spec_build_failed, reason}}
    end
  end

  # Same shape `do_deploy/1` wrote: a terminal status plus the reason, so the failure
  # is legible on the deployment page and not only in the release's step row.
  defp mark_failed(deployment, reason) do
    _ = Deployments.update_status(deployment, :failed, error: inspect(reason))
    :ok
  end

  @impl true
  def compensate(step, _ctx) do
    case step.resource_handle do
      %{"external_id" => external_id, "deployment_id" => deployment_id}
      when is_binary(external_id) ->
        _ = orchestrator().undeploy(external_id)

        case Deployments.get_deployment(deployment_id) do
          {:ok, deployment} ->
            Deployments.update_deployment(deployment, %{status: :stopped, external_id: nil})
            :ok

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  # Which donor CONTAINER this child was actually created against. The child's create
  # payload embeds that id, so once the donor is re-created the child cannot be started
  # again — recording it here is what lets the reconciler notice, since nothing about
  # the child's own row changes when the donor moves.
  defp record_netns_parent(deployment, %{netns_child: true, network: "container:" <> parent_id}) do
    Deployments.update_deployment(deployment, %{netns_parent_external_id: parent_id})
  end

  defp record_netns_parent(_deployment, _spec), do: :ok

  defp load_target(step, ctx) do
    case Map.get(step.resource_handle, "deployment_id") do
      nil -> Deployments.get_deployment!(ctx.deployment.id)
      id -> Deployments.get_deployment!(id)
    end
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
end
