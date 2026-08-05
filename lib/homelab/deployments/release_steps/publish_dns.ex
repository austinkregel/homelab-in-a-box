defmodule Homelab.Deployments.ReleaseSteps.PublishDns do
  @moduledoc """
  Publishes the deployment's A records — locally as `DnsRecord` rows and outward to
  every configured DNS provider. The saga equivalent of `do_deploy/1`'s
  `create_dns_records/1`, which the release path never ran: a saga-deployed app got a
  Traefik route and no name pointing at it.

  The address comes from `Deployments.detect_ip_config/0` — the same host-LAN-IP guess
  the imperative path used, shared rather than copied so the two cannot drift.

  ## Why this one DOES fail the release

  Unlike `EnsureIngressProxy`, a failure here is local and specific: `{:error, _}` from
  `ensure_deployment_dns_records/2` means the zone or the record row could not be
  written. Provider-side push failures do NOT surface here (they are recorded on the
  row as `last_sync_error`), so an install with no DNS provider still succeeds. A
  release that reports `:running` for a routed app whose name resolves nowhere is the
  exact "success for durable work that did not happen" this step exists to prevent.

  ## `compensate/2`

  A DNS A record is the one artifact in this plan that is externally visible and
  **cached by resolvers** — leaving it behind after a rollback points the world at a
  container that no longer exists, for as long as the TTL says. So it is undone.

  Via `Networking.cleanup_deployment_dns_records/1` rather than
  `list_dns_records_for_deployment/1` + `delete_dns_record/1`: the former filters to
  `managed: true` (never touching a record the operator created by hand) *and* pushes
  the deletion to the provider. Deleting only the local row would drop homelab's
  record of a record that still exists at Cloudflare — an orphan nothing can ever
  clean up. Idempotent: a second run finds nothing to delete.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Networking
  alias Homelab.Services.ActivityLog

  @impl true
  def run(step, ctx) do
    deployment = Deployments.get_deployment!(target_id(step, ctx))

    case Networking.ensure_deployment_dns_records(deployment, Deployments.detect_ip_config()) do
      {:ok, results} ->
        {written, failed} = Enum.split_with(results, &match?({:ok, _}, &1))

        if failed == [] do
          log_written(deployment, written)

          {:ok,
           %{
             "deployment_id" => deployment.id,
             "fqdn" => deployment.domain,
             "record_count" => length(written)
           }}
        else
          reason = Enum.map(failed, fn {:error, r} -> r end)
          activity_error(deployment, reason)
          {:error, {:publish_dns_failed, deployment.id, reason}}
        end

      {:error, reason} ->
        activity_error(deployment, reason)
        {:error, {:publish_dns_failed, deployment.id, reason}}
    end
  end

  @impl true
  def compensate(step, ctx) do
    deployment_id = Map.get(step.resource_handle || %{}, "deployment_id") || ctx.deployment.id
    _ = Networking.cleanup_deployment_dns_records(deployment_id)
    :ok
  end

  defp log_written(_deployment, []), do: :ok

  defp log_written(deployment, written) do
    ActivityLog.info(
      "dns",
      "Created #{length(written)} DNS record(s) for #{deployment.domain}",
      %{deployment_id: deployment.id}
    )
  end

  defp activity_error(deployment, reason) do
    ActivityLog.error(
      "dns",
      "Failed to create DNS records for #{deployment.domain}: #{inspect(reason)}",
      %{deployment_id: deployment.id}
    )
  end

  defp target_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") || ctx.deployment.id
  end
end
