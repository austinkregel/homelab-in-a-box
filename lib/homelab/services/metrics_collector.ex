defmodule Homelab.Services.MetricsCollector do
  @moduledoc """
  GenServer that polls Homelab.System.Metrics.collect/0 every 10 seconds,
  broadcasts via Phoenix.PubSub on topic "metrics:update", stores the latest
  metrics in state for retrieval via get_latest/0, and persists each snapshot
  into the `metric_samples` time-series table (Homelab.Telemetry) so the UI can
  render trends. Old samples are pruned on a slow schedule.
  """

  use GenServer

  require Logger

  alias Homelab.Telemetry

  @poll_interval :timer.seconds(10)
  @prune_interval :timer.hours(1)

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Returns the latest collected metrics. Blocks until available.
  """
  def get_latest do
    GenServer.call(__MODULE__, :get_latest)
  end

  @impl true
  def init(_opts) do
    schedule_poll()
    schedule_prune()
    {:ok, nil}
  end

  @impl true
  def handle_info(:poll, _state) do
    metrics = Homelab.System.Metrics.collect()

    traefik_metrics =
      case Homelab.System.TraefikMetrics.collect() do
        {:ok, data} -> data
        {:error, _} -> %{}
      end

    combined = Map.put(metrics, :traefik, traefik_metrics)

    # Persist before broadcasting so a subscriber that reloads series on the
    # broadcast sees this tick's sample already written.
    persist_snapshot(combined)
    Phoenix.PubSub.broadcast(Homelab.PubSub, "metrics:update", {:metrics, combined})
    schedule_poll()
    {:noreply, combined}
  end

  def handle_info(:prune, state) do
    # Retention is best-effort; a DB hiccup must not take the collector down.
    try do
      {deleted, _} = Telemetry.prune()
      if deleted > 0, do: Logger.debug("MetricsCollector pruned #{deleted} old metric samples")
    rescue
      e -> Logger.warning("MetricsCollector prune failed: #{Exception.message(e)}")
    end

    schedule_prune()
    {:noreply, state}
  end

  @impl true
  def handle_call(:get_latest, _from, state) do
    {:reply, state, state}
  end

  # Persisting is best-effort: the live PubSub broadcast already went out, so a
  # transient DB error just means one missing sample, never a crashed collector.
  defp persist_snapshot(combined) do
    try do
      Telemetry.record_snapshot(combined)
    rescue
      e -> Logger.warning("MetricsCollector failed to persist snapshot: #{Exception.message(e)}")
    end
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end

  defp schedule_prune do
    Process.send_after(self(), :prune, @prune_interval)
  end
end
