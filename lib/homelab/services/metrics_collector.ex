defmodule Homelab.Services.MetricsCollector do
  @moduledoc """
  GenServer that polls Homelab.System.Metrics.collect/0 every 10 seconds,
  broadcasts via Phoenix.PubSub on topic "metrics:update", and stores the
  latest metrics in state for retrieval via get_latest/0.
  """

  use GenServer

  @poll_interval :timer.seconds(10)

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

    Phoenix.PubSub.broadcast(Homelab.PubSub, "metrics:update", {:metrics, combined})
    schedule_poll()
    {:noreply, combined}
  end

  @impl true
  def handle_call(:get_latest, _from, state) do
    {:reply, state, state}
  end

  defp schedule_poll do
    Process.send_after(self(), :poll, @poll_interval)
  end
end
