defmodule Homelab.Services.ActivityLog do
  @moduledoc """
  In-memory ring buffer of recent system activity events.

  Stores the last N events so the dashboard can display a live
  activity feed without needing to tail server logs. Events are
  also broadcast via PubSub for real-time UI updates.
  """

  use Agent

  @max_events 100
  @pubsub_topic "activity:feed"

  def start_link(_opts) do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  @doc "Returns the PubSub topic for subscribing to activity events."
  def topic, do: @pubsub_topic

  @doc "Pushes a new event, broadcasts via PubSub, and persists to the audit log."
  def push(level, source, message, metadata \\ %{}) do
    event = %{
      id: System.unique_integer([:positive, :monotonic]),
      level: level,
      source: source,
      message: message,
      metadata: metadata,
      timestamp: DateTime.utc_now()
    }

    Agent.update(__MODULE__, fn events ->
      [event | events] |> Enum.take(@max_events)
    end)

    Phoenix.PubSub.broadcast(
      Homelab.PubSub,
      @pubsub_topic,
      {:activity_event, event}
    )

    persist_to_audit(level, source, message, metadata)

    event
  end

  @doc "Returns the most recent `count` events."
  def recent(count \\ 20) do
    Agent.get(__MODULE__, fn events ->
      Enum.take(events, count)
    end)
  end

  @doc "Returns all stored events."
  def all do
    Agent.get(__MODULE__, & &1)
  end

  def info(source, message, metadata \\ %{}), do: push(:info, source, message, metadata)
  def warn(source, message, metadata \\ %{}), do: push(:warn, source, message, metadata)
  def error(source, message, metadata \\ %{}), do: push(:error, source, message, metadata)

  defp persist_to_audit(level, source, message, metadata) do
    action = "#{source}.#{level}"
    resource_id = if metadata[:deployment_id], do: to_string(metadata[:deployment_id])

    try do
      Homelab.Audit.log(action, source, resource_id,
        metadata: Map.put(metadata, :message, message)
      )
    rescue
      _ -> :ok
    end
  end
end
