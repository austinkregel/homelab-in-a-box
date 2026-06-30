defmodule Homelab.Deployments.ReleaseSteps.PublishIngress do
  @moduledoc """
  Grants external reachability by connecting the reverse proxy to the deployment's
  network — the single, idempotent action that exposes a release, run only after
  the app has reached healthy. Mirrors the reconciler's ingress invariant.

  Network is `resource_handle["network"]` or, failing that, derived from the app
  deployment. `compensate/2` unpublishes, so a rolled-back release is never left
  externally reachable.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.SpecBuilder

  @impl true
  def run(step, ctx) do
    network = network_for(step, ctx)

    case orchestrator().publish(network) do
      :ok -> {:ok, %{"network" => network, "published" => true}}
      {:error, reason} -> {:error, {:publish_failed, network, reason}}
    end
  end

  @impl true
  def compensate(step, ctx) do
    network = step.resource_handle["network"] || network_for(step, ctx)
    _ = orchestrator().unpublish(network)
    :ok
  end

  defp network_for(step, ctx) do
    case step.resource_handle["network"] do
      net when is_binary(net) ->
        net

      _ ->
        deployment = Deployments.get_deployment!(ctx.deployment.id)
        SpecBuilder.deployment_network(deployment.tenant, deployment.app_template)
    end
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
end
