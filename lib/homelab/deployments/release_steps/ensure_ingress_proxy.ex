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

  The failure is not swallowed, though: it is written to the ActivityLog *and*
  recorded in `resource_handle` as `"ingress_proxy" => "unavailable"` with the
  reason, so a release that published a route onto a proxy nobody could ensure says
  so on the record. Actual reachability is still gated by `PublishIngress`, which
  does fail closed.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Infrastructure
  alias Homelab.Services.ActivityLog

  @impl true
  def run(step, ctx) do
    deployment_id = target_id(step, ctx)

    case Infrastructure.ensure_traefik() do
      {:ok, :already_running} ->
        {:ok, %{"ingress_proxy" => "already_running"}}

      {:ok, :started} ->
        ActivityLog.info("infrastructure", "Traefik started", %{deployment_id: deployment_id})
        {:ok, %{"ingress_proxy" => "started"}}

      {:error, reason} ->
        ActivityLog.error("infrastructure", "Traefik failed: #{inspect(reason)}", %{
          deployment_id: deployment_id
        })

        Logger.warning("[ensure_ingress_proxy] could not ensure Traefik: #{inspect(reason)}")

        {:ok, %{"ingress_proxy" => "unavailable", "error" => inspect(reason)}}
    end
  end

  defp target_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") ||
      (ctx.deployment && ctx.deployment.id)
  end
end
