defmodule Homelab.Services.CatalogSyncer do
  @moduledoc """
  GenServer that periodically syncs app catalogs from registries that support
  the :browse capability. Does not store data itself; registry drivers cache
  their own data. Schedules first sync 5 seconds after init to avoid delaying startup.
  """

  use GenServer

  @sync_interval :timer.hours(1)
  @initial_delay :timer.seconds(5)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Force an immediate catalog sync across all browse-capable registries.
  """
  def sync_now do
    GenServer.call(__MODULE__, :sync_now)
  end

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sync, @initial_delay)
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sync, state) do
    _ = sync_registries()
    schedule_next_sync()
    {:noreply, state}
  end

  @impl true
  def handle_call(:sync_now, _from, state) do
    result = sync_registries()
    {:reply, result, state}
  end

  defp sync_registries do
    catalogs = Homelab.Config.application_catalogs()

    results =
      Enum.map(catalogs, fn mod ->
        case mod.browse([]) do
          {:ok, entries} -> {mod, length(entries)}
          {:error, reason} -> {mod, {:error, reason}}
        end
      end)

    total =
      Enum.reduce(results, 0, fn
        {_, count}, acc when is_integer(count) -> acc + count
        _, acc -> acc
      end)

    Enum.each(results, fn
      {mod, count} when is_integer(count) ->
        require Logger
        Logger.info("[CatalogSyncer] #{mod.display_name()}: synced #{count} entries")

      {mod, {:error, reason}} ->
        require Logger
        Logger.warning("[CatalogSyncer] #{mod.display_name()}: sync failed - #{inspect(reason)}")
    end)

    require Logger
    Logger.info("[CatalogSyncer] Sync complete. Total entries fetched: #{total}")

    {:ok, total}
  end

  defp schedule_next_sync do
    Process.send_after(self(), :sync, @sync_interval)
  end
end
