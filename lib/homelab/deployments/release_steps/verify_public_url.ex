defmodule Homelab.Deployments.ReleaseSteps.VerifyPublicUrl do
  @moduledoc """
  The step that means what the release claims: this deployment is reachable at its URL.

  `PublishIngress` — the step this one follows, and which used to end every routed
  release — asserts that the workload is attached to the shared ingress network. That is
  a precondition of reachability, not reachability. A release could reach `:running`
  with the container attached, the Domain row written and the A records published, while
  a browser still got a hold page: Traefik rebuilds its router from the container's START
  event, ACME may still be issuing the certificate for a name on its own apex, and an
  external DNS record propagates on its provider's schedule. Every one of those windows
  sat *after* the last step the release had.

  So the last step now asks the question the operator is actually asking, end to end and
  in the order a browser hits it:

    1. **A certificate is served for this name.** Via `TlsProbe`, which completes a real
       handshake and reads the leaf. Covers DNS resolving and something listening on 443
       as a side effect of needing them, and separates "ACME has not issued yet" (Traefik
       serves its default cert) from "the name does not resolve".
    2. **A request reaches the app.** Via `UrlProbe`, which distinguishes the workload's
       own answer from `HomelabWeb.Plugs.HoldingPage`'s interstitial by the `x-hiab-hold`
       header. Any status the app produces counts — see `UrlProbe`.

  ## Advisory: it reports, it does not roll back

  Registered in `ReleaseRunner`'s `@advisory_steps`, so a failure here marks the step and
  lets the release settle instead of compensating.

  This is the one step where fail-closed would be wrong. Everything it waits on is
  outside the deploy: a DNS record's TTL at the provider, an ACME order, a resolver's
  cache. Rolling back would undeploy a container that is running correctly, withdraw the
  records that were about to start resolving, and leave the operator with nothing — over
  a certificate that arrived ninety seconds later. `AwaitHealth` fails closed because
  what it waits on is the deploy itself; this waits on the internet.

  Failing loudly still matters, which is why it is not simply reported as success: a
  deployment whose URL never came up is the single most common thing an operator wants
  told, and the recorded reason names which of the two stages did not pass.

  ## The probe runs from the box

  Worth knowing when reading a failure. A homelab whose router does not implement NAT
  hairpin cannot reach its own public address from inside, so this can report a name
  unreachable that is perfectly reachable from outside. The recorded reason distinguishes
  the shapes — a handshake that never connects reads differently from a hold page — but
  the vantage point is a real limitation of testing the public URL rather than the
  local route.

  No `compensate/2`: probing creates nothing to undo.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments

  @default_timeout_ms 90_000
  @default_interval_ms 3_000

  @impl true
  def run(step, ctx) do
    deployment_id = Map.get(step.resource_handle, "deployment_id") || ctx.deployment.id
    deployment = Deployments.get_deployment!(deployment_id)

    case domain_of(deployment) do
      nil ->
        # Planned only for deployments that hold a name, so this is a race (the domain
        # was cleared between plan and run), not a misplan. Nothing to verify.
        {:ok, %{"verified" => false, "reason" => "no domain"}}

      domain ->
        deadline = System.monotonic_time(:millisecond) + step_timeout_ms(step)
        poll(domain, deadline, step_interval_ms(step))
    end
  end

  defp domain_of(%{domain: domain}) when is_binary(domain) and domain != "", do: domain
  defp domain_of(_deployment), do: nil

  # The reason reported on timeout is the LAST round's, not the first: a name that
  # resolved and then started serving hold pages should say so, rather than still
  # blaming the DNS failure it opened with.
  defp poll(domain, deadline, interval) do
    case check(domain) do
      {:ok, result} ->
        {:ok, result}

      {:pending, reason} ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:url_unreachable, domain, reason}}
        else
          Process.sleep(interval)
          poll(domain, deadline, interval)
        end
    end
  end

  # Ordered so the reported reason is the FIRST thing in the chain that is not ready,
  # which is the one worth acting on. Reporting "no answer from the app" while the name
  # does not resolve would send the operator to look at the container.
  defp check(domain) do
    with {:ok, tls} <- probe_tls(domain),
         :ok <- certificate_ready(tls, domain) do
      probe_url(domain, tls)
    end
  end

  defp probe_tls(domain) do
    case tls_probe().inspect_domain(domain) do
      {:ok, tls} -> {:ok, tls}
      {:error, reason} -> {:pending, {:tls_handshake_failed, reason}}
    end
  end

  # Traefik serves its built-in placeholder while ACME has not issued for the name, which
  # a browser rejects outright — so "a cert was served" is not enough, it has to be one
  # that covers this name.
  defp certificate_ready(%{self_signed?: true}, _domain), do: {:pending, :certificate_pending}

  defp certificate_ready(%{covers_domain?: false}, domain),
    do: {:pending, {:certificate_does_not_cover, domain}}

  defp certificate_ready(_tls, _domain), do: :ok

  defp probe_url(domain, tls) do
    case url_probe().reach(domain) do
      {:ok, %{served_by: :app, status: status, url: url}} ->
        {:ok,
         %{
           "verified" => true,
           "url" => url,
           "status" => status,
           "tls_issuer" => Map.get(tls, :issuer),
           "tls_days_remaining" => Map.get(tls, :days_remaining)
         }}

      {:ok, %{served_by: :hold, hold_state: state}} ->
        {:pending, {:holding, state}}

      {:error, reason} ->
        {:pending, {:request_failed, reason}}
    end
  end

  defp step_timeout_ms(step) do
    case Map.get(step.resource_handle, "timeout_ms") do
      ms when is_integer(ms) and ms > 0 -> ms
      _ -> Application.get_env(:homelab, :verify_url_timeout_ms, @default_timeout_ms)
    end
  end

  defp step_interval_ms(_step),
    do: Application.get_env(:homelab, :verify_url_interval_ms, @default_interval_ms)

  defp tls_probe, do: Application.get_env(:homelab, :tls_probe, Homelab.Networking.TlsProbe)
  defp url_probe, do: Application.get_env(:homelab, :url_probe, Homelab.Networking.UrlProbe)
end
