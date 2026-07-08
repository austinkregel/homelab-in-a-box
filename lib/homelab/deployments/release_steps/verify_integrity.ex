defmodule Homelab.Deployments.ReleaseSteps.VerifyIntegrity do
  @moduledoc """
  The final adoption gate: confirm the managed replacement is actually healthy
  and *stays* healthy before the release is allowed to land `:running`.

  It polls the deployment's container like `AwaitHealth` (healthy if the template
  declares a healthcheck, else `running`), then holds a stability window and
  re-checks — so a crash-looping replacement that momentarily reports `running`
  fails the gate (triggering the runner's reverse-order rollback which resumes
  the original) instead of passing at the first sight of `running`.

  No `compensate/2`: checking creates nothing to undo.

  Config: `:verify_integrity_timeout_ms` (default 120_000),
  `:verify_integrity_stable_ms` (default 10_000).
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.SpecBuilder

  @impl true
  def run(_step, ctx) do
    deployment_id = ctx.deployment.id
    deadline = System.monotonic_time(:millisecond) + timeout_ms()

    with :ok <- poll_until_ready(deployment_id, deadline),
         :ok <- hold_stable(deployment_id) do
      {:ok, %{"verified" => true}}
    end
  end

  defp poll_until_ready(deployment_id, deadline) do
    cond do
      ready?(deployment_id) ->
        :ok

      System.monotonic_time(:millisecond) >= deadline ->
        {:error, {:integrity_failed, deployment_id, :not_ready}}

      true ->
        Process.sleep(interval_ms())
        poll_until_ready(deployment_id, deadline)
    end
  end

  # Hold the stability window, then re-confirm readiness. A container that dies
  # during the window fails the gate.
  defp hold_stable(deployment_id) do
    Process.sleep(stable_ms())

    if ready?(deployment_id) do
      :ok
    else
      {:error, {:integrity_failed, deployment_id, :unstable}}
    end
  end

  defp ready?(deployment_id) do
    deployment = Deployments.get_deployment!(deployment_id)
    declares_hc? = SpecBuilder.declares_healthcheck?(Access.effective_health_check(deployment))

    case deployment.external_id do
      nil ->
        false

      external_id ->
        case orchestrator().get_service(external_id) do
          {:ok, service} when declares_hc? -> Map.get(service, :health) == :healthy
          {:ok, service} -> Map.get(service, :state) == :running
          _ -> false
        end
    end
  end

  defp orchestrator, do: Homelab.Config.orchestrator()
  defp timeout_ms, do: Application.get_env(:homelab, :verify_integrity_timeout_ms, 120_000)
  defp interval_ms, do: Application.get_env(:homelab, :await_health_interval_ms, 3_000)
  defp stable_ms, do: Application.get_env(:homelab, :verify_integrity_stable_ms, 10_000)
end
