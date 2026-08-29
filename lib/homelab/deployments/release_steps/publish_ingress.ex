defmodule Homelab.Deployments.ReleaseSteps.PublishIngress do
  @moduledoc """
  Asserts that the app's workload is on the shared ingress network — the idempotent
  action that makes a release externally reachable, run after the app reaches healthy.
  Mirrors the reconciler's ingress invariant.

  It is no longer what FIRST attaches a freshly deployed container. Both drivers now put
  every network on the workload before it starts — the Engine between create and start
  (`DockerEngine.attach_then_start/2`), Swarm in the service spec
  (`DockerSwarm.build_networks/1`) — because Traefik resolves a backend from the START
  event, and attaching afterwards left it routing to the tenant network. So on the normal
  deploy path this step now finds the workload already attached and says so.

  That does not make it redundant. It is what covers a workload that becomes routable
  WITHOUT a fresh create, and it is the release's own assertion that the thing it just
  deployed is actually reachable rather than an assumption that the driver managed it.

  `compensate/2` detaches it again, so a rolled-back release is never left externally
  reachable.

  That last sentence used to be false. Both this step and its compensation acted on
  `homelab_<tenant>_<app>_net`, a per-deployment network nothing is ever attached to —
  connecting and disconnecting Traefik from an empty network changes nothing, so a
  rolled-back release stayed reachable and the step reported success either way.
  Traefik resolves a backend by the container's address on the network named in its
  `traefik.docker.network` label, so it is the WORKLOAD's membership of that network
  that decides reachability.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments

  @impl true
  def run(_step, ctx) do
    deployment = Deployments.get_deployment!(ctx.deployment.id)

    case Deployments.publish_deployment(deployment) do
      :ok ->
        {:ok, %{"published" => true, "external_id" => deployment.external_id}}

      {:error, reason} ->
        {:error, {:publish_failed, deployment.id, reason}}
    end
  end

  @impl true
  def compensate(step, ctx) do
    # Prefer the id this step actually published, so a compensation still severs the
    # right container even if the row has since been reset. Falls back to the current
    # row, and does nothing at all when neither yields one — a release that never got a
    # container has nothing to detach.
    case Deployments.get_deployment(ctx.deployment.id) do
      {:ok, deployment} ->
        _ = Deployments.unpublish_deployment(published_container(step, deployment))
        :ok

      _ ->
        :ok
    end
  end

  # Through `Deployments.unpublish_deployment/1` rather than the driver directly, so the
  # "can this workload be attached at all?" rule lives in exactly one place. A container
  # in another container's namespace was never on the ingress network and the daemon
  # refuses to detach it.
  defp published_container(step, deployment) do
    case step.resource_handle["external_id"] do
      id when is_binary(id) -> %{deployment | external_id: id}
      _ -> deployment
    end
  end
end
