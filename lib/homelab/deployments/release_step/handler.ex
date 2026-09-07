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

  `skip?/2` is the runtime gate, evaluated immediately before `run/2`: `{:skip, message}`
  records a `:skipped` step carrying that message, and omitting the callback means
  "always run". `ctx.facts` holds the `ReleaseFacts` for the step's target; see
  `ReleaseSteps.Conditions`.
  """

  @type ctx :: %{
          required(:release) => struct(),
          required(:deployment) => struct() | nil,
          optional(:facts) => struct()
        }
  @type handle :: map()

  @callback run(step :: struct(), ctx) :: {:ok, handle} | {:error, term()}
  @callback compensate(step :: struct(), ctx) :: :ok | {:error, term()}
  @callback skip?(step :: struct(), ctx) :: :run | {:skip, String.t()}

  @optional_callbacks compensate: 2, skip?: 2
end
