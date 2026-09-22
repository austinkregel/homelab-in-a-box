defmodule Homelab.Services.CertManager do
  @moduledoc """
  Monitors TLS certificate expiry and triggers renewals through
  the configured gateway.

  It also owns the TLS-enforcement latch. A fresh box serves plain HTTP — Traefik is
  provisioned without the HTTP->HTTPS redirect, because redirecting to an entrypoint
  that is still presenting Traefik's built-in self-signed default makes the control
  plane unreachable rather than merely unencrypted, and a domain registered this
  morning can be a day away from resolving.

  So each pass asks the one question that settles it: does the base domain *actually*
  serve a real certificate right now? `Homelab.Networking.TlsProbe` answers with a
  handshake rather than with the gateway's opinion, which matters here — Traefik
  reports a router as active while serving the default cert. The first time the answer
  is yes, the latch is set and the next `ensure_traefik/0` adds the redirect.

  One way only. Nothing here clears the latch, so a certificate that later expires or
  fails to renew produces alarms, never a silent downgrade of an already-HTTPS box back
  to plain HTTP.
  """

  use GenServer
  require Logger

  @default_interval :timer.hours(6)
  @renewal_threshold_days 30

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def status do
    GenServer.call(__MODULE__, :status)
  end

  def check_now do
    GenServer.cast(__MODULE__, :check_now)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      jitter = :rand.uniform(:timer.seconds(15))
      Process.send_after(self(), :check_certs, jitter)
    end

    {:ok, %{interval: interval, enabled: enabled, last_check_at: nil, renewed_count: 0}}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state, state}
  end

  @impl true
  def handle_cast(:check_now, state) do
    send(self(), :check_certs)
    {:noreply, state}
  end

  @impl true
  def handle_info(:check_certs, state) do
    gateway = Homelab.Config.gateway()

    if gateway do
      threshold = DateTime.utc_now() |> DateTime.add(@renewal_threshold_days, :day)
      expiring = Homelab.Networking.list_expiring_tls(threshold)
      renewed = renew_certs(gateway, expiring)

      check_pending_domains(gateway)
      maybe_enforce_tls()

      Process.send_after(self(), :check_certs, state.interval)

      {:noreply,
       %{
         state
         | last_check_at: DateTime.utc_now(),
           renewed_count: state.renewed_count + renewed
       }}
    else
      Process.send_after(self(), :check_certs, state.interval)
      {:noreply, %{state | last_check_at: DateTime.utc_now()}}
    end
  end

  # Flips the redirect on the first time the base domain serves a certificate a browser
  # would accept. Anything else — a handshake that fails, the self-signed default, a
  # cert for some other name, an expired one — leaves the box on plain HTTP, which is
  # reachable, rather than on a redirect to a cert the browser refuses.
  defp maybe_enforce_tls do
    base = Homelab.Config.base_domain()

    cond do
      Homelab.Infrastructure.tls_enforced?() ->
        :ok

      is_nil(base) or base == "" ->
        :ok

      true ->
        case tls_probe().inspect_domain(base) do
          # `:expiring` is a trusted cert that happens to be near renewal — a browser
          # accepts it, so it is every bit as good a reason to start enforcing as
          # `:valid`. Renewal is `renew_certs/2`'s job, not this latch's.
          {:ok, %{status: status}} when status in [:valid, :expiring] ->
            Homelab.Infrastructure.enforce_tls!()

          {:ok, %{status: status}} ->
            Logger.debug(
              "CertManager: #{base} is serving a #{status} certificate; staying on plain HTTP"
            )

            :ok

          {:error, reason} ->
            Logger.debug(
              "CertManager: could not read #{base}'s certificate (#{inspect(reason)}); " <>
                "staying on plain HTTP"
            )

            :ok
        end
    end
  end

  # The same seam `VerifyPublicUrl` and the deployment page read, so a test that merely
  # ticks this loop does not open a real TLS connection to the internet.
  defp tls_probe, do: Application.get_env(:homelab, :tls_probe, Homelab.Networking.TlsProbe)

  defp check_pending_domains(gateway) do
    pending = Homelab.Networking.list_pending_tls()

    Enum.each(pending, fn domain ->
      case tls_probe().inspect_domain(domain.fqdn) do
        # Already serving a certificate a browser accepts, so there is nothing to
        # provision. This is the common case and it used to be invisible: a wildcard
        # `*.<base>` covers every subdomain the moment it is issued, and no `pending`
        # domain under it ever needs its own certificate — but `provision_tls/1` only
        # answers for a name with a router of its own, so those rows sat at `:pending`
        # indefinitely while being served perfectly well.
        #
        # The handshake also carries the real `notAfter`. What went in here before was
        # `utc_now() + 90 days`, a date no certificate has, which then drove the
        # renewal pass above.
        {:ok, %{status: status, not_after: not_after}} when status in [:valid, :expiring] ->
          Logger.info("TLS active for #{domain.fqdn} (expires #{DateTime.to_date(not_after)})")

          Homelab.Networking.update_domain(domain, %{
            tls_status: :active,
            tls_expires_at: DateTime.truncate(not_after, :second)
          })

        # Anything else — the self-signed default, a cert for another name, an expired
        # one, no handshake at all — means the name still needs a certificate. Ask the
        # gateway to provision, and leave the row `:pending` either way so the next
        # pass tries again. `provision_tls/1` reporting `:active` is not evidence of a
        # certificate; it only means a router exists.
        _ ->
          case gateway.provision_tls(domain.fqdn) do
            {:ok, _} -> :ok
            {:error, _reason} -> :ok
          end
      end
    end)
  end

  defp renew_certs(gateway, domains) do
    Enum.count(domains, fn domain ->
      case gateway.provision_tls(domain.fqdn) do
        {:ok, _cert_info} ->
          record_renewal(domain)

        {:error, reason} ->
          Logger.error("Failed to renew TLS for #{domain.fqdn}: #{inspect(reason)}")

          Homelab.Networking.update_domain(domain, %{tls_status: :failed})

          false
      end
    end)
  end

  # Records the expiry the name is ACTUALLY serving, and counts a renewal only when that
  # date moved forward.
  #
  # `provision_tls/1` returning `:ok` means Traefik has a router with a cert resolver
  # attached — not that ACME issued anything. Writing `utc_now() + 90 days` on the
  # strength of it took a domain that had just failed to renew straight back out of
  # `list_expiring_tls/1` for two months, so a renewal that kept failing was reported as
  # having succeeded every six hours until the certificate expired underneath it.
  defp record_renewal(domain) do
    case tls_probe().inspect_domain(domain.fqdn) do
      {:ok, %{status: status, not_after: not_after}} when status in [:valid, :expiring] ->
        expires_at = DateTime.truncate(not_after, :second)

        Homelab.Networking.update_domain(domain, %{
          tls_status: :active,
          tls_expires_at: expires_at
        })

        if moved_forward?(domain.tls_expires_at, expires_at) do
          Logger.info("Renewed TLS for #{domain.fqdn} (expires #{DateTime.to_date(not_after)})")
          true
        else
          # Still the old certificate. ACME is not instant, so this is expected on the
          # pass that requested it; staying inside the renewal window is what gets it
          # asked again rather than forgotten.
          Logger.info("#{domain.fqdn} is still serving its previous certificate")
          false
        end

      other ->
        Logger.error(
          "Requested TLS for #{domain.fqdn} but it is not serving a usable certificate: " <>
            inspect(other)
        )

        false
    end
  end

  defp moved_forward?(nil, _new), do: true
  defp moved_forward?(previous, new), do: DateTime.compare(new, previous) == :gt
end
