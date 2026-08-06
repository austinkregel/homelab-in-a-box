defmodule Homelab.Deployments.ReleaseSteps.EnsureIngressProxy do
  @moduledoc """
  Ensures the shared ingress proxy (Traefik) exists before a routed release builds
  anything that depends on it. Carries `do_deploy/1`'s `ensure_traefik_if_needed/1`
  into the saga, which had no equivalent at all — a release planned by
  `deploy_release/2` published ingress onto a proxy nobody had ensured was running.

  ## Why position 1

  Planned FIRST, ahead of every container in the plan. Two reasons:

    * The proxy is a precondition of the route, not a product of it. Ensuring it
      after the workload exists means the workload is up and unreachable for the
      duration.
    * If ensuring it is going to fail loudly, it should fail before any container
      exists, so there is nothing to unwind.

  ## Why there is NO `compensate/2` — do not add one

  Traefik is a **shared singleton**. Every routed deployment on this host resolves
  through the same container. Stopping or removing it because *one* release rolled
  back would sever every other deployment's route — a whole-host outage caused by a
  single failed deploy. This step's "creation" is idempotent convergence of shared
  infrastructure, and shared infrastructure is not this release's to destroy.

  A future reader will read "step with a side effect and no compensation" as an
  omission. It is not. Leave it.

  ## Why a failure here does NOT fail the release

  Deliberately best-effort, exactly as `do_deploy/1` was: `ensure_traefik/0` returns
  `{:error, :dns_token_missing}` on any install that has not configured a DNS-01
  token, which is the normal state for a LAN-only homelab and for anyone running
  Traefik from their own compose file. Hard-failing here would make *every* routed
  deploy impossible on those installs — a far worse regression than the gap it would
  close, and a behaviour change to a path this step is meant to preserve.

  ## What actually backstops this — NOT what this moduledoc used to claim

  It used to say "actual reachability is still gated by `PublishIngress`, which does
  fail closed." That is false. `publish_deployment/1` -> `DockerEngine.publish/2`
  CREATES the ingress network itself (`ensure_network/1`) and attaches the container to
  it. It fails closed on the ATTACHMENT, and never checks that Traefik exists or is on
  that network. A missing proxy passes it every time.

  What is true is narrower, and worth stating exactly because it is the whole safety
  argument:

    * The attach is genuinely fail-closed, on every topology. Where `publish_ingress`
      is planned it happens there; where it is NOT planned (netns donor, netns child,
      `:host_network`) it still happens at container-create time via
      `DockerEngine.maybe_connect_routing_network/2`, which returns
      `{:network_attach_failed, _, _}` rather than swallowing it.
    * So "the workload is on the ingress network" is guaranteed. "Something is
      listening on the other end of it" is not guaranteed by anything in the plan.

  A missing proxy is therefore a real and reachable outcome of a green release, which
  is why the failure is recorded rather than merely logged: to the ActivityLog, to
  `resource_handle` as `"ingress_proxy" => "unavailable"` with the reason, and — since
  neither of those reaches the operator, one being a 100-entry ring buffer and the
  other rendered nowhere — onto the step's own `error_message`, which the release card
  renders underneath the step. The release is green and says why the route may not
  resolve.

  Not failing the release is still right: `{:error, :dns_token_missing}` is the
  expected-normal return for a LAN-only install and for anyone running Traefik from
  their own compose file, and hard-failing would make every routed deploy on those
  hosts impossible. The defect class this tier removes is "reports success for work it
  did not do" — and a step that completes while saying, on the record the operator
  reads, that it could not ensure the proxy is not that.

  That contract only holds if EVERY return is handled. `ensure_traefik/0` is a `with`
  with no `else`, so it returns whatever any clause returned, and a `case` listing only
  the expected shapes would raise `CaseClauseError` — which the runner's rescue turns
  into a failed step and a full rollback. Hence the catch-all.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Releases
  alias Homelab.Infrastructure
  alias Homelab.Services.ActivityLog

  @impl true
  def run(step, ctx) do
    deployment_id = target_id(step, ctx)

    case ensure_proxy() do
      {:ok, :already_running} ->
        {:ok, %{"ingress_proxy" => "already_running"}}

      {:ok, :started} ->
        ActivityLog.info("infrastructure", "Traefik started", %{deployment_id: deployment_id})
        {:ok, %{"ingress_proxy" => "started"}}

      # A catch-all, NOT just `{:error, reason}`. `ensure_traefik/0` is a `with` with no
      # `else`, so it returns whatever any clause returned — including
      # `Docker.Network.ensure/1`'s shapes. Matching only the three expected returns
      # raises `CaseClauseError`, which the runner's rescue turns into a failed step and
      # a full rollback: the precise inversion of this module's contract.
      other ->
        unavailable(step, other, deployment_id)
    end
  end

  defp unavailable(step, result, deployment_id) do
    reason = inspect(result)

    # On the STEP row, which is the only durable, release-scoped place an operator
    # actually looks — the release card renders this field under the step. The
    # ActivityLog entry below is a 100-entry ring buffer and the `resource_handle` key
    # is rendered nowhere, so without this a release reports `:running` for a route no
    # proxy is serving and says nothing about it anywhere the operator will see.
    _ = Releases.record_step_note(step, "Traefik not ensured: #{reason}")

    # WARN, not error. This step is best-effort by construction, and
    # `{:error, :dns_token_missing}` is the expected-normal return for a LAN-only
    # install — logging at error severity would put a red row on the Activity feed for
    # every routed deploy on a correctly configured host, in a 100-entry ring buffer
    # that other events then age out of.
    ActivityLog.warn("infrastructure", "Traefik not ensured: #{reason}", %{
      deployment_id: deployment_id
    })

    Logger.warning("[ensure_ingress_proxy] could not ensure Traefik: #{reason}")

    {:ok, %{"ingress_proxy" => "unavailable", "error" => reason}}
  end

  # Overridable so a test can drive the returns `ensure_traefik/0` can actually produce
  # — including the ones it produces by accident, which is the branch that matters.
  defp ensure_proxy do
    case Application.get_env(:homelab, :ingress_proxy_ensurer) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Infrastructure.ensure_traefik()
    end
  end

  defp target_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") ||
      (ctx.deployment && ctx.deployment.id)
  end
end
