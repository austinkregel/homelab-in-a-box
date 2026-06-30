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
    deadline = System.monotonic_time(:millisecond) + timeout_ms()
    poll(deployment_id, deadline)
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
        if declares_hc? do
          Map.get(service, :health) == :healthy
        else
          Map.get(service, :state) == :running
        end

      _ ->
        false
    end
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
  defp timeout_ms, do: Application.get_env(:homelab, :await_health_timeout_ms, 120_000)
  defp interval_ms, do: Application.get_env(:homelab, :await_health_interval_ms, 3_000)
end
