defmodule Homelab.Deployments.ReleaseSteps.AwaitHealth do
  @moduledoc """
  Blocks until a deployment's container is ready — `:healthy` when the template
  declares a healthcheck, otherwise `running`. This is the ordering barrier that
  makes a dependency (MySQL) usable before the step that consumes it runs.

  Target is `resource_handle["deployment_id"]` (the companion) or `ctx.deployment`
  (the app). On timeout it returns `{:error, :health_timeout}`, which the runner
  turns into a rollback — matching the "deploy timed out" fail-closed behaviour.

  No `compensate/2`: waiting creates nothing to undo.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.SpecBuilder

  @impl true
  def run(step, ctx) do
    deployment_id = Map.get(step.resource_handle, "deployment_id") || ctx.deployment.id
    deadline = System.monotonic_time(:millisecond) + step_timeout_ms(step)
    poll(deployment_id, deadline)
  end

  # A per-step override, because not every wait is waiting for the same thing. The default
  # is sized for "this container should come up"; adoption's wait for a network donor is
  # queued behind ANOTHER service's data copy, which for a media library is minutes to
  # hours. Sharing one global timeout means either that rolls back for no reason or every
  # ordinary healthcheck hangs far too long.
  defp step_timeout_ms(step) do
    case Map.get(step.resource_handle, "timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> timeout_ms()
    end
  end

  defp poll(deployment_id, deadline) do
    deployment = Deployments.get_deployment!(deployment_id)
    declares_hc? = SpecBuilder.declares_healthcheck?(Access.effective_health_check(deployment))

    cond do
      ready?(deployment, declares_hc?) ->
        {:ok, %{"healthy" => true}}

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:health_timeout, deployment_id}}

      true ->
        Process.sleep(interval_ms())
        poll(deployment_id, deadline)
    end
  end

  defp ready?(%{external_id: nil}, _declares_hc?), do: false

  defp ready?(%{external_id: external_id}, declares_hc?) do
    case orchestrator().get_service(external_id) do
      {:ok, service} ->
        # `:none` means the driver could not tell us, NOT that the workload is unhealthy.
        # Requiring `:healthy` outright made a declared healthcheck a foot-gun on any
        # driver that cannot report one: the gate never passed, the step timed out after
        # its deadline, and the release rolled back a workload that was up. That was live
        # on Swarm, where health was hardcoded `:none`.
        #
        # Falling back to `:running` rather than failing keeps the healthcheck meaningful
        # where it IS reported — `:starting` and `:unhealthy` still hold the gate — while
        # an unknown answer degrades to the same signal a workload without a healthcheck
        # gets, which is the strongest thing left that is actually true. The reconciler
        # has made the same trade since before this step existed.
        case {declares_hc?, Map.get(service, :health, :none)} do
          {true, :none} -> Map.get(service, :state) == :running
          {true, health} -> health == :healthy
          {false, _} -> Map.get(service, :state) == :running
        end

      _ ->
        false
    end
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
  defp timeout_ms, do: Application.get_env(:homelab, :await_health_timeout_ms, 120_000)
  defp interval_ms, do: Application.get_env(:homelab, :await_health_interval_ms, 3_000)
end
