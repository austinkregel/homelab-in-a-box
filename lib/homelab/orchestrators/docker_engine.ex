defmodule Homelab.Orchestrators.DockerEngine do
  @moduledoc """
  Plain Docker Engine implementation of the Orchestrator behaviour.

  Uses the container API directly — no Swarm mode required. Ideal for
  local development where `docker swarm init` would interfere with
  other projects on the same machine.

  Containers are identified by their service name and labeled with
  `homelab.managed=true` for safe filtering during reconciliation.
  """

  @behaviour Homelab.Behaviours.Orchestrator

  alias Homelab.Docker.Client

  @impl true
  def driver_id, do: "docker_engine"

  @impl true
  def display_name, do: "Docker Engine"

  @impl true
  def description, do: "Standalone containers — no Swarm required"

  @routing_network "homelab-internal"

  @impl true
  def deploy(spec) do
    with :ok <- ensure_network(spec.network),
         :ok <- pull_image(spec.image) do
      body = build_container_payload(spec)

      case Client.post("/containers/create?name=#{spec.service_name}", body) do
        {:ok, %{"Id" => id}} ->
          case Client.post("/containers/#{id}/start") do
            {:ok, _} ->
              maybe_connect_routing_network(id, spec)
              {:ok, id}

            {:error, reason} ->
              {:error, reason}
          end

        {:error, {:conflict, _}} ->
          _ = Client.post("/containers/#{spec.service_name}/stop")
          _ = Client.delete("/containers/#{spec.service_name}?force=true")

          case Client.post("/containers/create?name=#{spec.service_name}", body) do
            {:ok, %{"Id" => id}} ->
              case Client.post("/containers/#{id}/start") do
                {:ok, _} ->
                  maybe_connect_routing_network(id, spec)
                  {:ok, id}

                {:error, reason} ->
                  {:error, reason}
              end

            {:error, reason} ->
              {:error, reason}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @impl true
  def undeploy(service_id) do
    networks = container_networks(service_id)
    _ = Client.post("/containers/#{service_id}/stop")

    result =
      case Client.delete("/containers/#{service_id}?force=true") do
        {:ok, _} -> :ok
        {:error, {:not_found, _}} -> :ok
        {:error, reason} -> {:error, reason}
      end

    if result == :ok, do: prune_deployment_networks(networks)
    result
  end

  @impl true
  def update(service_id, spec) do
    with :ok <- undeploy(service_id),
         {:ok, _new_id} <- deploy(spec) do
      :ok
    end
  end

  @impl true
  def restart(service_id) do
    case Client.post("/containers/#{service_id}/restart") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_services do
    filters = Jason.encode!(%{"label" => ["homelab.managed=true"]})

    case Client.get("/containers/json?all=true&filters=#{URI.encode(filters)}") do
      {:ok, containers} when is_list(containers) ->
        {:ok, Enum.map(containers, &parse_container_status/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def get_service(service_id) do
    case Client.get("/containers/#{service_id}/json") do
      {:ok, container} when is_map(container) ->
        {:ok, parse_inspect_status(container)}

      {:error, {:not_found, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def health_check(service_id) do
    case Client.get("/containers/#{service_id}/json") do
      {:ok, %{"State" => %{"Running" => true}}} ->
        {:ok, :healthy}

      {:ok, %{"State" => _}} ->
        {:ok, :unhealthy}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def stats(service_id) do
    case Client.get("/containers/#{service_id}/stats?stream=false") do
      {:ok, data} when is_map(data) ->
        {:ok, parse_stats(data)}

      {:error, {:not_found, _}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def logs(service_id, opts \\ []) do
    tail = Keyword.get(opts, :tail, 100)
    timestamps = if Keyword.get(opts, :timestamps, false), do: "true", else: "false"

    path =
      "/containers/#{service_id}/logs?stdout=true&stderr=true&tail=#{tail}&timestamps=#{timestamps}"

    case Client.get(path) do
      {:ok, body} when is_binary(body) -> {:ok, strip_docker_log_headers(body)}
      {:ok, body} -> {:ok, inspect(body)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp maybe_connect_routing_network(container_id, spec) do
    bridge_networks = Map.get(spec, :bridge_networks, [])

    Enum.each(bridge_networks, fn net ->
      ensure_network(net)
      Client.post("/networks/#{net}/connect", %{"Container" => container_id})
    end)

    needs_routing? =
      spec.labels["traefik.enable"] == "true" or Map.get(spec, :service_mode, false)

    if needs_routing? do
      ensure_network(@routing_network)
      Client.post("/networks/#{@routing_network}/connect", %{"Container" => container_id})
      Homelab.Infrastructure.connect_traefik_to_network(spec.network)
    end
  end

  # --- Image Management ---

  defp pull_image(image) do
    require Logger
    Logger.info("[DockerEngine] Pulling image #{image}...")

    case Client.post_stream("/images/create?fromImage=#{URI.encode(image)}") do
      :ok ->
        Logger.info("[DockerEngine] Image #{image} pulled successfully")
        :ok

      {:error, reason} ->
        Logger.error("[DockerEngine] Failed to pull image #{image}: #{inspect(reason)}")
        {:error, {:pull_failed, image, reason}}
    end
  end

  # --- Payload Builders ---

  defp build_container_payload(spec) do
    mounts = build_mounts(spec.volumes)
    {exposed_ports, port_bindings} = build_port_config(spec.ports)

    payload = %{
      "Image" => spec.image,
      "Env" => env_to_list(spec.env),
      "Labels" => spec.labels,
      "HostConfig" => %{
        "Memory" => spec.memory_limit,
        "NanoCpus" => spec.cpu_limit,
        "NetworkMode" => spec.network,
        "RestartPolicy" => %{"Name" => "on-failure", "MaximumRetryCount" => 3},
        "Mounts" => mounts,
        "PortBindings" => port_bindings
      }
    }

    if map_size(exposed_ports) > 0 do
      Map.put(payload, "ExposedPorts", exposed_ports)
    else
      payload
    end
  end

  defp build_port_config(ports) when is_list(ports) and length(ports) > 0 do
    exposed =
      ports
      |> Enum.map(fn p -> {"#{p.internal}/tcp", %{}} end)
      |> Map.new()

    bindings =
      ports
      |> Enum.map(fn p ->
        {"#{p.internal}/tcp", [%{"HostPort" => to_string(p.external)}]}
      end)
      |> Map.new()

    {exposed, bindings}
  end

  defp build_port_config(_), do: {%{}, %{}}

  defp build_mounts(volumes) do
    Enum.map(volumes, fn vol ->
      mount = %{
        "Target" => vol.target,
        "Source" => vol.source,
        "Type" => Map.get(vol, :type, "volume")
      }

      if mount["Type"] == "volume" do
        Map.put(mount, "VolumeOptions", %{})
      else
        mount
      end
    end)
  end

  defp env_to_list(env) when is_map(env) do
    Enum.map(env, fn {key, value} -> "#{key}=#{value}" end)
  end

  # --- Network Management ---

  defp ensure_network(network_name) do
    case Client.get("/networks/#{network_name}") do
      {:ok, _} ->
        :ok

      {:error, {:not_found, _}} ->
        case Client.post("/networks/create", %{"Name" => network_name, "Driver" => "bridge"}) do
          {:ok, _} -> :ok
          {:error, reason} -> {:error, {:network_create_failed, reason}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp container_networks(service_id) do
    case Client.get("/containers/#{service_id}/json") do
      {:ok, %{"NetworkSettings" => %{"Networks" => networks}}} ->
        Map.keys(networks)

      _ ->
        []
    end
  end

  defp prune_deployment_networks(network_names) do
    network_names
    |> Enum.filter(&String.ends_with?(&1, "_net"))
    |> Enum.each(fn name ->
      case Client.get("/networks/#{name}") do
        {:ok, %{"Containers" => containers}} when map_size(containers) == 0 ->
          require Logger
          Logger.info("[DockerEngine] Removing empty deployment network #{name}")
          Client.delete("/networks/#{name}")

        _ ->
          :ok
      end
    end)
  end

  # --- Response Parsers ---

  defp parse_container_status(container) do
    labels = container["Labels"] || %{}
    names = container["Names"] || []
    name = names |> List.first("") |> String.trim_leading("/")

    %{
      id: container["Id"],
      name: name,
      state: map_container_state(container["State"]),
      replicas: if(container["State"] == "running", do: 1, else: 0),
      image: container["Image"] || "",
      labels: labels
    }
  end

  defp parse_inspect_status(container) do
    config = container["Config"] || %{}
    state = container["State"] || %{}
    name = (container["Name"] || "") |> String.trim_leading("/")

    %{
      id: container["Id"],
      name: name,
      state: map_inspect_state(state),
      replicas: if(state["Running"], do: 1, else: 0),
      image: config["Image"] || "",
      labels: config["Labels"] || %{}
    }
  end

  defp map_container_state("running"), do: :running
  defp map_container_state("exited"), do: :stopped
  defp map_container_state("dead"), do: :failed
  defp map_container_state("created"), do: :pending
  defp map_container_state("restarting"), do: :pending
  defp map_container_state(_), do: :stopped

  defp map_inspect_state(%{"Running" => true}), do: :running
  defp map_inspect_state(%{"Dead" => true}), do: :failed
  defp map_inspect_state(%{"Restarting" => true}), do: :pending
  defp map_inspect_state(_), do: :stopped

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
