defmodule Homelab.Services.CertManager do
  @moduledoc """
  Monitors TLS certificate expiry and triggers renewals through
  the configured gateway.
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

  defp check_pending_domains(gateway) do
    pending = Homelab.Networking.list_pending_tls()

    Enum.each(pending, fn domain ->
      case gateway.provision_tls(domain.fqdn) do
        {:ok, %{status: :active}} ->
          Logger.info("TLS active for #{domain.fqdn}")

          Homelab.Networking.update_domain(domain, %{
            tls_status: :active,
            tls_expires_at: DateTime.utc_now() |> DateTime.add(90, :day)
          })

        {:ok, _} ->
          :ok

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp renew_certs(gateway, domains) do
    Enum.count(domains, fn domain ->
      case gateway.provision_tls(domain.fqdn) do
        {:ok, _cert_info} ->
          Logger.info("Renewed TLS for #{domain.fqdn}")

          Homelab.Networking.update_domain(domain, %{
            tls_status: :active,
            tls_expires_at: DateTime.utc_now() |> DateTime.add(90, :day)
          })

          true

        {:error, reason} ->
          Logger.error("Failed to renew TLS for #{domain.fqdn}: #{inspect(reason)}")

          Homelab.Networking.update_domain(domain, %{tls_status: :failed})

          false
      end
    end)
  end
end
