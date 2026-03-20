defmodule Homelab.Orchestrators.DockerSwarm do
  @moduledoc """
  Docker Swarm implementation of the Orchestrator behaviour.

  Translates orchestrator-agnostic service specs into Docker Swarm API
  calls. All managed services are labeled with `homelab.managed=true`
  for safe identification during reconciliation.
  """

  @behaviour Homelab.Behaviours.Orchestrator

  alias Homelab.Docker.Client

  @routing_network "homelab-internal"

  @impl true
  def driver_id, do: "docker_swarm"

  @impl true
  def display_name, do: "Docker Swarm"

  @impl true
  def description, do: "Multi-node clustering with built-in load balancing"

  @impl true
  def deploy(spec) do
    with :ok <- pull_image(spec.image) do
      body = build_service_create_payload(spec)

      case Client.post("/services/create", body) do
        {:ok, %{"ID" => id}} -> {:ok, id}
        {:ok, body} when is_map(body) -> {:ok, body["ID"] || body["id"]}
        {:error, {:conflict, _}} -> {:error, :already_exists}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp pull_image(image) do
    require Logger
    Logger.info("[DockerSwarm] Pulling image #{image}...")

    case Client.post_stream("/images/create?fromImage=#{URI.encode(image)}") do
      :ok ->
        Logger.info("[DockerSwarm] Image #{image} pulled successfully")
        :ok

      {:error, reason} ->
        Logger.error("[DockerSwarm] Failed to pull image #{image}: #{inspect(reason)}")
        {:error, {:pull_failed, image, reason}}
    end
  end

  @impl true
  def undeploy(service_id) do
    case Client.delete("/services/#{service_id}") do
      {:ok, _} -> :ok
      {:error, {:not_found, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def update(service_id, spec) do
    with {:ok, existing} <- Client.get("/services/#{service_id}"),
         version <- get_in(existing, ["Version", "Index"]) do
      body = build_service_update_payload(spec)

      case Client.post("/services/#{service_id}/update?version=#{version}", body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def restart(service_id) do
    with {:ok, existing} <- Client.get("/services/#{service_id}"),
         version <- get_in(existing, ["Version", "Index"]) do
      # Force update by toggling the ForceUpdate counter
      force_update =
        get_in(existing, ["Spec", "TaskTemplate", "ForceUpdate"]) || 0

      body =
        existing["Spec"]
        |> put_in(["TaskTemplate", "ForceUpdate"], force_update + 1)

      case Client.post("/services/#{service_id}/update?version=#{version}", body) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @impl true
  def list_services do
    filters = Jason.encode!(%{"label" => ["homelab.managed=true"]})

    case Client.get("/services?filters=#{URI.encode(filters)}") do
      {:ok, services} when is_list(services) ->
        {:ok, Enum.map(services, &parse_service_status/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_service(service_id) do
    case Client.get("/services/#{service_id}") do
      {:ok, service} when is_map(service) ->
        {:ok, parse_service_status(service)}

      {:error, {:not_found, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health_check(service_id) do
    tasks_filter = Jason.encode!(%{"service" => [service_id], "desired-state" => ["running"]})

    case Client.get("/tasks?filters=#{URI.encode(tasks_filter)}") do
      {:ok, tasks} when is_list(tasks) ->
        if Enum.all?(tasks, &task_healthy?/1) and tasks != [] do
          {:ok, :healthy}
        else
          {:ok, :unhealthy}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stats(service_id) do
    with {:ok, container_id} <- get_running_container_id(service_id),
         {:ok, data} <- Client.get("/containers/#{container_id}/stats?stream=false") do
      {:ok, parse_stats(data)}
    end
  end

  defp get_running_container_id(service_id) do
    tasks_filter = Jason.encode!(%{"service" => [service_id], "desired-state" => ["running"]})

    case Client.get("/tasks?filters=#{URI.encode(tasks_filter)}") do
      {:ok, tasks} when is_list(tasks) ->
        running_task =
          Enum.find(tasks, fn t ->
            get_in(t, ["Status", "State"]) == "running"
          end)

        case running_task do
          nil ->
            {:error, :no_running_container}

          task ->
            container_id = get_in(task, ["Status", "ContainerStatus", "ContainerID"])
            if container_id, do: {:ok, container_id}, else: {:error, :no_container_id}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_stats(data) do
    cpu_percent = calc_cpu_percent(data)
    memory_usage = get_in(data, ["memory_stats", "usage"]) || 0
    memory_limit = get_in(data, ["memory_stats", "limit"]) || 0

    {network_rx, network_tx} =
      (data["networks"] || %{})
      |> Enum.reduce({0, 0}, fn {_iface, stats}, {rx_acc, tx_acc} ->
        rx = Map.get(stats, "rx_bytes", 0) + rx_acc
        tx = Map.get(stats, "tx_bytes", 0) + tx_acc
        {rx, tx}
      end)

    %{
      cpu_percent: cpu_percent,
      memory_usage: memory_usage,
      memory_limit: memory_limit,
      network_rx: network_rx,
      network_tx: network_tx
    }
  end

  defp calc_cpu_percent(%{"cpu_stats" => cpu_stats, "precpu_stats" => precpu_stats}) do
    cpu_usage = cpu_stats["cpu_usage"] || %{}
    precpu_usage = precpu_stats["cpu_usage"] || %{}
    total_delta = (cpu_usage["total"] || 0) - (precpu_usage["total"] || 0)
    system_delta = (cpu_stats["system_cpu_usage"] || 0) - (precpu_stats["system_cpu_usage"] || 0)
    num_cpus = cpu_stats["online_cpus"] || 1

    if system_delta > 0 and num_cpus > 0 do
      total_delta / system_delta * num_cpus * 100
    else
      0.0
    end
  end

  defp calc_cpu_percent(_), do: 0.0

  @impl true
  def logs(service_id, opts \\ []) do
    tail = Keyword.get(opts, :tail, 100)
    timestamps = if Keyword.get(opts, :timestamps, false), do: "true", else: "false"

    path =
      "/services/#{service_id}/logs?stdout=true&stderr=true&tail=#{tail}&timestamps=#{timestamps}"

    case Client.get(path) do
      {:ok, body} when is_binary(body) -> {:ok, strip_docker_log_headers(body)}
      {:ok, body} -> {:ok, inspect(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Payload Builders ---

  defp build_service_create_payload(spec) do
    networks = build_networks(spec)

    %{
      "Name" => spec.service_name,
      "Labels" => spec.labels,
      "TaskTemplate" => %{
        "ContainerSpec" => %{
          "Image" => spec.image,
          "Env" => env_to_list(spec.env)
        },
        "Resources" => %{
          "Limits" => %{
            "MemoryBytes" => spec.memory_limit,
            "NanoCPUs" => spec.cpu_limit
          }
        },
        "Networks" => networks,
        "RestartPolicy" => %{
          "Condition" => "on-failure",
          "MaxAttempts" => 3,
          "Delay" => 5_000_000_000
        }
      },
      "Mode" => %{
        "Replicated" => %{
          "Replicas" => spec.replicas
        }
      },
      "EndpointSpec" => build_endpoint_spec(spec.ports)
    }
    |> maybe_add_mounts(spec)
  end

  defp build_networks(spec) do
    primary = [%{"Target" => spec.network}]
    bridges = Enum.map(Map.get(spec, :bridge_networks, []), &%{"Target" => &1})

    routing =
      if spec.labels["traefik.enable"] == "true" or Map.get(spec, :service_mode, false) do
        [%{"Target" => @routing_network}]
      else
        []
      end

    primary ++ bridges ++ routing
  end

  defp build_endpoint_spec(ports) when is_list(ports) and length(ports) > 0 do
    port_configs =
      Enum.map(ports, fn p ->
        %{
          "Protocol" => "tcp",
          "TargetPort" => String.to_integer(to_string(p.internal)),
          "PublishedPort" => String.to_integer(to_string(p.external)),
          "PublishMode" => "ingress"
        }
      end)

    %{"Mode" => "vip", "Ports" => port_configs}
  end

  defp build_endpoint_spec(_), do: %{"Mode" => "vip"}

  defp build_service_update_payload(spec) do
    build_service_create_payload(spec)
  end

  defp maybe_add_mounts(payload, spec) do
    case spec.volumes do
      [] ->
        payload

      volumes ->
        mounts =
          Enum.map(volumes, fn vol ->
            %{
              "Source" => vol.source,
              "Target" => vol.target,
              "Type" => vol[:type] || "bind",
              "ReadOnly" => false
            }
          end)

        put_in(payload, ["TaskTemplate", "ContainerSpec", "Mounts"], mounts)
    end
  end

  defp env_to_list(env) when is_map(env) do
    Enum.map(env, fn {key, value} -> "#{key}=#{value}" end)
  end

  # --- Response Parsers ---

  defp parse_service_status(service) do
    spec = service["Spec"] || %{}
    container_spec = get_in(spec, ["TaskTemplate", "ContainerSpec"]) || %{}
    mode = spec["Mode"] || %{}

    replicas =
      case mode do
        %{"Replicated" => %{"Replicas" => n}} -> n
        _ -> 1
      end

    %{
      id: service["ID"],
      name: spec["Name"],
      state: infer_service_state(service),
      replicas: replicas,
      image: container_spec["Image"] || "",
      labels: spec["Labels"] || %{}
    }
  end

  defp infer_service_state(service) do
    update_status = service["UpdateStatus"]

    cond do
      update_status && update_status["State"] == "rollback_completed" -> :failed
      update_status && update_status["State"] == "updating" -> :pending
      true -> :running
    end
  end

  defp task_healthy?(%{"Status" => %{"State" => "running"}}), do: true
  defp task_healthy?(_), do: false

  # Docker log output has 8-byte headers per frame. Strip them for readability.
  defp strip_docker_log_headers(binary) when is_binary(binary) do
    binary
    |> String.split("\n")
    |> Enum.map(fn line ->
      if byte_size(line) > 8 do
        <<_header::binary-size(8), rest::binary>> = line
        rest
      else
        line
      end
    end)
    |> Enum.join("\n")
  end
end
