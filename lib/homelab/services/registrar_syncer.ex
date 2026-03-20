defmodule Homelab.Services.RegistrarSyncer do
  @moduledoc """
  Periodically syncs the domain list from the configured registrar provider
  into local `dns_zones` records. Runs every 6 hours by default.
  """

  use GenServer
  require Logger

  alias Homelab.Services.ActivityLog

  @default_interval :timer.hours(6)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Force an immediate sync."
  def sync_now do
    GenServer.cast(__MODULE__, :sync_now)
  end

  @doc "Returns the last sync result."
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @default_interval)
    enabled = Keyword.get(opts, :enabled, true)

    if enabled do
      Process.send_after(self(), :sync, :timer.seconds(30))
    end

    {:ok,
     %{
       interval: interval,
       last_sync_at: nil,
       last_result: nil,
       enabled: enabled
     }}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, Map.take(state, [:last_sync_at, :last_result]), state}
  end

  @impl true
  def handle_cast(:sync_now, state) do
    send(self(), :sync)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sync, state) do
    result = do_sync()
    schedule_next(state.interval)

    {:noreply, %{state | last_sync_at: DateTime.utc_now(), last_result: result}}
  end

  defp do_sync do
    case Homelab.Config.registrar() do
      nil ->
        {:ok, :no_registrar}

      _registrar ->
        Logger.info("[RegistrarSyncer] Starting domain sync")

        case Homelab.Networking.sync_zones_from_registrar() do
          {:ok, results} ->
            count = length(results)
            Logger.info("[RegistrarSyncer] Synced #{count} zone(s)")

            ActivityLog.info("dns", "Synced #{count} zone(s) from registrar")
            {:ok, count}

          {:error, reason} ->
            Logger.error("[RegistrarSyncer] Sync failed: #{inspect(reason)}")

            ActivityLog.error("dns", "Registrar sync failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp schedule_next(interval) do
    Process.send_after(self(), :sync, interval)
  end
end
