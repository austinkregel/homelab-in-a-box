defmodule Homelab.Deployments.ReleaseSteps.NoopHandler do
  @moduledoc """
  Default step handler: logs and succeeds without touching any orchestrator.

  This is the `ReleaseRunner`'s fallback when no concrete handler is registered
  for a step type (see `Homelab.Deployments.ReleaseRunner` and the
  `:release_step_handlers` config). It lets the saga engine be exercised
  end-to-end — ordering, leases, transitions, compensation — before the real
  Docker handlers (`:adopt_volume`, `:adopt_container`, `:backup_verify`, …) are
  implemented, and keeps unregistered step types from crashing a release.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  @impl true
  def run(step, _ctx) do
    Logger.info("[release] noop run step ##{step.position} (#{step.type})")
    {:ok, %{"noop" => true, "type" => to_string(step.type)}}
  end

  @impl true
  def compensate(step, _ctx) do
    Logger.info("[release] noop compensate step ##{step.position} (#{step.type})")
    :ok
  end
end
