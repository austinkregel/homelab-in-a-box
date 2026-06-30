defmodule Homelab.Deployments.ReleaseSteps.ResumeOld do
  @moduledoc """
  The forward partner of `:quiesce_old`: restores the old container's original
  restart policy and starts it again — so in Phase 1 the stack keeps running on
  the originals after each service's data has been copied. The original stays the
  rollback until the operator confirms the permanent home at cutover.

  Expects `step.resource_handle["container"]` and `["restart_policy"]` (the
  original policy, supplied by the planner from discovery). `compensate/2`
  re-quiesces (disable policy + stop) so a rollback past this step doesn't leave a
  double-writer.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Migrate.ContainerControl

  @impl true
  def run(step, _ctx) do
    id = step.resource_handle["container"]
    policy = step.resource_handle["restart_policy"] || "no"
    Logger.info("[resume_old] restoring restart=#{policy} + starting #{id}")

    with :ok <- ops().set_restart_policy(id, policy),
         :ok <- ops().start(id) do
      {:ok, %{"resumed" => true, "container" => id, "restart_policy" => policy}}
    else
      {:error, reason} -> {:error, {:resume_failed, id, reason}}
    end
  end

  @impl true
  def compensate(step, _ctx) do
    case step.resource_handle["container"] do
      id when is_binary(id) ->
        _ = ops().set_restart_policy(id, "no")
        _ = ops().stop(id, stop_timeout())
        :ok

      _ ->
        :ok
    end
  end

  defp ops, do: Application.get_env(:homelab, :container_ops, ContainerControl)
  defp stop_timeout, do: Application.get_env(:homelab, :quiesce_stop_timeout, 60)
end
