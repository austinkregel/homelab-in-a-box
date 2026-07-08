defmodule Homelab.Services.WorkbenchJanitor do
  @moduledoc """
  Periodically purges stale Workbench workspaces from disk.

  The Workbench keeps throwaway build contexts on disk keyed by user id
  (`Homelab.Workbench`). This GenServer sweeps them once an hour, deleting any
  workspace untouched for longer than the configured TTL (`ttl_hours`). It holds
  no state beyond the timer and is safe to run on every node.
  """

  use GenServer

  require Logger

  @interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, @interval)
    schedule(interval)
    {:ok, %{interval: interval}}
  end

  @impl true
  def handle_info(:purge, %{interval: interval} = state) do
    purged = Homelab.Workbench.purge_stale()

    if purged > 0 do
      Logger.info("[WorkbenchJanitor] Purged #{purged} stale workspace(s)")
    end

    schedule(interval)
    {:noreply, state}
  end

  defp schedule(interval), do: Process.send_after(self(), :purge, interval)
end
