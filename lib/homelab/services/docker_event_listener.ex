defmodule Homelab.Services.DockerEventListener do
  @moduledoc """
  Streams real-time container lifecycle events from the Docker daemon
  and updates deployment status accordingly.

  Provides the fast, event-driven path for deployment status: a container
  becoming healthy publishes it and marks it `:running`; a container dying
  unpublishes it. Continuous convergence (and recovery of any events missed
  while disconnected) is owned by `Homelab.Services.Reconciler`, which this
  listener nudges on every (re)connect.
  """

  use GenServer
  require Logger

  alias Homelab.Docker.Client, as: DockerClient
  alias Homelab.Deployments
  alias Homelab.Services.ActivityLog
  alias Homelab.Services.Reconciler

  @pubsub_topic "deployments:status"
  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the PubSub topic for deployment status changes."
  def topic, do: @pubsub_topic

  @impl true
  def init(opts) do
    # Test seam: a `:docker_client` option scopes the Docker client to THIS
    # process (the façade reads `Process.get(:docker_client)` first), so tests
    # can drive the stream without mutating global config. No-op in production.
    if client = Keyword.get(opts, :docker_client), do: Process.put(:docker_client, client)

    state = %{
      stream_resp: nil,
      buffer: "",
      reconnect_attempts: 0,
      connected: false
    }

    {:ok, state, {:continue, :startup}}
  end

  @impl true
  def handle_continue(:startup, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  @impl true
  def handle_info(:connect, state) do
    filters = %{
      "type" => ["container"],
      "label" => ["homelab.managed=true"]
    }

    case DockerClient.stream_events(filters) do
      {:ok, resp} ->
        Logger.info("[DockerEventListener] Connected to Docker event stream")
        # Recover any lifecycle events missed while we were disconnected.
        Reconciler.request_sync()

        {:noreply,
         %{state | stream_resp: resp, buffer: "", reconnect_attempts: 0, connected: true}}

      {:error, reason} ->
        Logger.warning(
          "[DockerEventListener] Failed to connect to Docker events: #{inspect(reason)}"
        )

        {:noreply, schedule_reconnect(state)}
    end
  end

  def handle_info(message, %{stream_resp: %Req.Response{} = resp} = state) do
    case Req.parse_message(resp, message) do
      {:ok, chunks} ->
        state = process_chunks(chunks, state)
        {:noreply, state}

      :unknown ->
        {:noreply, state}
    end
  end

  def handle_info(:reconnect, state) do
    send(self(), :connect)
    {:noreply, state}
  end

  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def terminate(_reason, %{stream_resp: %Req.Response{} = resp}) do
    Req.cancel_async_response(resp)
    :ok
  end

  def terminate(_reason, _state), do: :ok

  defp process_chunks([], state), do: state

  defp process_chunks([:done | _], state) do
    Logger.info("[DockerEventListener] Event stream closed, will reconnect")
    schedule_reconnect(state)
    %{state | stream_resp: nil, connected: false}
  end

  defp process_chunks([{:error, reason} | _], state) do
    Logger.warning("[DockerEventListener] Stream error: #{inspect(reason)}, will reconnect")
    schedule_reconnect(state)
    %{state | stream_resp: nil, connected: false}
  end

  defp process_chunks([{:data, data} | rest], state) do
    combined = state.buffer <> data
    {lines, remaining} = split_lines(combined)

    Enum.each(lines, fn line ->
      line = String.trim(line)

      if line != "" do
        case Jason.decode(line) do
          {:ok, event} ->
            handle_docker_event(event)

          {:error, _} ->
            Logger.debug("[DockerEventListener] Skipping malformed event line")
        end
      end
    end)

    process_chunks(rest, %{state | buffer: remaining})
  end

  defp process_chunks([{:trailers, _} | rest], state), do: process_chunks(rest, state)

  defp split_lines(data) do
    parts = String.split(data, "\n")

    case parts do
      [single] -> {[], single}
      lines -> {Enum.slice(lines, 0..-2//1), List.last(lines)}
    end
  end

  defp handle_docker_event(%{"Type" => "container", "Action" => action} = event) do
    attrs = get_in(event, ["Actor", "Attributes"]) || %{}
    deployment_id_str = attrs["homelab.deployment_id"]

    if deployment_id_str do
      case Integer.parse(deployment_id_str) do
        {deployment_id, _} ->
          process_container_event(action, deployment_id, attrs)

        :error ->
          :ok
      end
    end
  end

  defp handle_docker_event(_event), do: :ok

  defp process_container_event(action, deployment_id, attrs) do
    case Deployments.get_deployment(deployment_id) do
      {:ok, deployment} ->
        apply_event(action, deployment, attrs)

      {:error, :not_found} ->
        :ok
    end
  end

  # A bare start no longer means "running". The container exists but is not yet
  # verified ready, so it stays inaccessible (:deploying). Readiness is signalled
  # by a healthcheck (health_status: healthy) or, for checkless containers, by the
  # reconciler's running-and-stable window. Fail-closed.
  defp apply_event("start", deployment, _attrs) do
    case Deployments.transition_status(deployment, :deploying, [:pending]) do
      {:ok, _} -> broadcast_status(deployment.id, :deploying)
      {:noop, _} -> :ok
    end
  end

  # Verified ready: grant the public route (ingress only) and mark running.
  defp apply_event("health_status: healthy", deployment, _attrs) do
    case Deployments.transition_status(deployment, :running, [:pending, :deploying, :running]) do
      {:ok, updated} ->
        Deployments.publish_deployment(updated)
        broadcast_status(deployment.id, :running)

        if deployment.status != :running do
          ActivityLog.info("deploy", "#{deployment.app_template.name} is healthy and live", %{
            deployment_id: deployment.id
          })
        end

      {:noop, _} ->
        :ok
    end
  end

  # Sustained unhealthy: sever the public route and demote so it can recover.
  defp apply_event("health_status: unhealthy", deployment, _attrs) do
    Deployments.unpublish_deployment(deployment)

    case Deployments.transition_status(deployment, :deploying, [:running]) do
      {:ok, _} -> broadcast_status(deployment.id, :deploying)
      {:noop, _} -> :ok
    end

    ActivityLog.warn("deploy", "#{deployment.app_template.name} health check: unhealthy", %{
      deployment_id: deployment.id
    })
  end

  defp apply_event("die", deployment, attrs) do
    exit_code = parse_exit_code(attrs["exitCode"])

    cond do
      deployment.status in [:stopped, :removing] ->
        :ok

      exit_code == 0 ->
        mark_down(deployment, :stopped, [:pending, :deploying, :running])

      true ->
        Deployments.unpublish_deployment(deployment)
        error_msg = "Container exited with code #{exit_code}"

        case Deployments.transition_status(deployment, :failed, [:pending, :deploying, :running],
               error: error_msg
             ) do
          {:ok, _} ->
            broadcast_status(deployment.id, :failed)

            ActivityLog.error("deploy", "#{deployment.app_template.name} failed: #{error_msg}", %{
              deployment_id: deployment.id
            })

          {:noop, _} ->
            :ok
        end
    end
  end

  defp apply_event("stop", deployment, _attrs) do
    mark_down(deployment, :stopped, [:pending, :deploying, :running])
  end

  defp apply_event("kill", deployment, _attrs) do
    mark_down(deployment, :stopped, [:pending, :deploying, :running])
  end

  defp apply_event(_action, _deployment, _attrs), do: :ok

  defp mark_down(deployment, status, from_states) do
    Deployments.unpublish_deployment(deployment)

    case Deployments.transition_status(deployment, status, from_states) do
      {:ok, _} -> broadcast_status(deployment.id, status)
      {:noop, _} -> :ok
    end
  end

  defp parse_exit_code(nil), do: 1

  defp parse_exit_code(code) when is_integer(code), do: code

  defp parse_exit_code(code) when is_binary(code) do
    case Integer.parse(code) do
      {n, _} -> n
      :error -> 1
    end
  end

  defp broadcast_status(deployment_id, status) do
    Phoenix.PubSub.broadcast(
      Homelab.PubSub,
      @pubsub_topic,
      {:deployment_status, deployment_id, status}
    )
  end

  defp schedule_reconnect(state) do
    attempts = state.reconnect_attempts + 1
    delay = min(@reconnect_base_ms * round(:math.pow(2, min(attempts, 10))), @reconnect_max_ms)
    Process.send_after(self(), :reconnect, delay)
    %{state | reconnect_attempts: attempts, connected: false, stream_resp: nil}
  end
end
