defmodule Homelab.Services.DockerEventListener do
  @moduledoc """
  Streams real-time container lifecycle events from the Docker daemon
  and updates deployment status accordingly.

  Replaces the polling-based Reconciler and HealthMonitor with an
  event-driven approach using Docker's `/events` API endpoint.

  On startup, performs a one-time sync to reconcile any state changes
  that occurred while the application was offline.
  """

  use GenServer
  require Logger

  alias Homelab.Docker.Client, as: DockerClient
  alias Homelab.Deployments
  alias Homelab.Services.ActivityLog

  @pubsub_topic "deployments:status"
  @reconnect_base_ms 1_000
  @reconnect_max_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Returns the PubSub topic for deployment status changes."
  def topic, do: @pubsub_topic

  @impl true
  def init(_opts) do
    state = %{
      stream_resp: nil,
      buffer: "",
      reconnect_attempts: 0,
      connected: false
    }

    {:ok, state, {:continue, :startup_sync}}
  end

  @impl true
  def handle_continue(:startup_sync, state) do
    startup_sync()
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

  defp apply_event("start", deployment, _attrs) do
    if deployment.status != :running do
      Deployments.update_status(deployment, :running)
      broadcast_status(deployment.id, :running)

      app_name = deployment.app_template.name
      ActivityLog.info("deploy", "#{app_name} is running")
    end
  end

  defp apply_event("die", deployment, attrs) do
    exit_code = parse_exit_code(attrs["exitCode"])

    cond do
      deployment.status in [:stopped, :removing] ->
        :ok

      exit_code == 0 ->
        if deployment.status != :stopped do
          Deployments.update_status(deployment, :stopped)
          broadcast_status(deployment.id, :stopped)
        end

      true ->
        error_msg = "Container exited with code #{exit_code}"
        Deployments.update_status(deployment, :failed, error: error_msg)
        broadcast_status(deployment.id, :failed)

        app_name = deployment.app_template.name

        ActivityLog.error("deploy", "#{app_name} failed: #{error_msg}", %{
          deployment_id: deployment.id
        })
    end
  end

  defp apply_event("stop", deployment, _attrs) do
    if deployment.status not in [:stopped, :removing] do
      Deployments.update_status(deployment, :stopped)
      broadcast_status(deployment.id, :stopped)
    end
  end

  defp apply_event("kill", deployment, _attrs) do
    if deployment.status not in [:stopped, :removing] do
      Deployments.update_status(deployment, :stopped)
      broadcast_status(deployment.id, :stopped)
    end
  end

  defp apply_event("health_status: unhealthy", deployment, _attrs) do
    app_name = deployment.app_template.name

    ActivityLog.warn("deploy", "#{app_name} health check: unhealthy", %{
      deployment_id: deployment.id
    })
  end

  defp apply_event(_action, _deployment, _attrs), do: :ok

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

  defp startup_sync do
    case Homelab.Config.orchestrator() do
      nil ->
        :ok

      orchestrator ->
        Logger.info("[DockerEventListener] Running startup sync")

        case orchestrator.list_services() do
          {:ok, services} ->
            managed =
              Enum.filter(services, &(Map.get(&1.labels, "homelab.managed") == "true"))

            actual_by_id = Map.new(managed, &{&1.id, &1})

            deployments = Deployments.list_desired_states()

            Enum.each(deployments, fn deployment ->
              if deployment.external_id do
                case Map.get(actual_by_id, deployment.external_id) do
                  nil ->
                    if deployment.status not in [:stopped, :pending] do
                      Deployments.update_status(deployment, :failed,
                        error: "Container not found after restart"
                      )

                      broadcast_status(deployment.id, :failed)
                    end

                  service ->
                    expected = derive_status(service)

                    if deployment.status != expected do
                      Deployments.update_status(deployment, expected)
                      broadcast_status(deployment.id, expected)
                    end
                end
              end
            end)

          {:error, reason} ->
            Logger.error("[DockerEventListener] Startup sync failed: #{inspect(reason)}")
        end
    end
  end

  defp derive_status(%{state: :running}), do: :running
  defp derive_status(%{state: :failed}), do: :failed
  defp derive_status(%{state: :stopped}), do: :stopped
  defp derive_status(%{state: :pending}), do: :deploying
  defp derive_status(_), do: :running
end
