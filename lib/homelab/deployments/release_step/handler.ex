defmodule Homelab.Deployments.ReleaseStep.Handler do
  @moduledoc """
  Behaviour for executing and compensating a single `ReleaseStep`.

  The `ReleaseRunner` owns the saga control flow (ordering, leases, state
  transitions, the compensation walk); a handler owns only the side effect for
  one step type. Both callbacks MUST be idempotent — a crashed-then-resumed
  release re-runs the in-flight step from scratch, and compensation may be
  retried — so handlers key off `step.resource_handle` / the live orchestrator
  state rather than assuming they run exactly once.

  `run/2` returns `{:ok, handle}` where `handle` is a map describing what was
  created (a container `external_id`, a network name, a backup snapshot id, …);
  it is merged into the step's `resource_handle` so `compensate/2` can undo it
  without re-deriving anything. `compensate/2` is optional — a step with no
  externally-visible side effect (e.g. a pure health check) can omit it.
  """

  @type ctx :: %{required(:release) => struct(), required(:deployment) => struct() | nil}
  @type handle :: map()

  @callback run(step :: struct(), ctx) :: {:ok, handle} | {:error, term()}
  @callback compensate(step :: struct(), ctx) :: :ok | {:error, term()}

  @optional_callbacks compensate: 2
end
