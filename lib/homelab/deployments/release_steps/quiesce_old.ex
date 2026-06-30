defmodule Homelab.Deployments.ReleaseSteps.QuiesceOld do
  @moduledoc """
  Stops the old container so its data can be copied consistently, and — critically
  — **disables its restart policy first** so the daemon cannot resurrect a stopped
  `restart: always` database into a split-brain double-writer while the copy runs.

  It records the container's original restart policy in the step handle so
  compensation (and the later `:resume_old` step) can restore it. `compensate/2`
  re-enables the policy and restarts the container — i.e. it un-quiesces on
  rollback, leaving the original serving exactly as before.

  Expects `step.resource_handle["container"]` (a container id or name). Stop
  timeout is `config :homelab, :quiesce_stop_timeout` (default 60s — generous so
  databases flush cleanly on SIGTERM).
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Migrate.ContainerControl

  @impl true
  def run(step, _ctx) do
    id = step.resource_handle["container"]
    Logger.info("[quiesce_old] disabling restart policy + stopping #{id}")

    with {:ok, original} <- ops().restart_policy(id),
         :ok <- ops().set_restart_policy(id, "no"),
         :ok <- ops().stop(id, stop_timeout()) do
      {:ok, %{"quiesced" => true, "container" => id, "original_restart_policy" => original}}
    else
      {:error, reason} -> {:error, {:quiesce_failed, id, reason}}
    end
  end

  @impl true
  def compensate(step, _ctx) do
    case step.resource_handle do
      %{"container" => id, "original_restart_policy" => policy} when is_binary(id) ->
        _ = ops().set_restart_policy(id, policy || "no")
        _ = ops().start(id)
        :ok

      _ ->
        :ok
    end
  end

  defp ops, do: Application.get_env(:homelab, :container_ops, ContainerControl)
  defp stop_timeout, do: Application.get_env(:homelab, :quiesce_stop_timeout, 60)
end
