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
  alias Homelab.Docker.Network
  alias Homelab.Deployments.GpuSpec

  @impl true
  def driver_id, do: "docker_engine"

  @impl true
  def display_name, do: "Docker Engine"

  @impl true
  def description, do: "Standalone containers — no Swarm required"

  # Must match Homelab.Infrastructure's backbone network (namespaced to avoid
  # colliding with an existing stack's `homelab-internal`).
  @routing_network "homelab-iab-internal"

  @impl true
  def deploy(spec) do
    # Pull FIRST, then ensure the network immediately before create. The image pull
    # can take tens of seconds; doing `ensure_network` before it left a wide window
    # in which the freshly-created (empty) network could be removed — by a racing
    # cleanup, a sibling deploy's rollback, or a prune — before the container ever
    # attached, surfacing as "network <name> not found" at create time. Ensuring the
    # network right before the create closes that window.
    with :ok <- pull_image(spec.image),
         :ok <- ensure_network(spec.network) do
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

  @impl true
  def list_networks do
    case Client.get("/networks") do
      {:ok, networks} when is_list(networks) ->
        {:ok, Enum.map(networks, &parse_network/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_volumes do
    case Client.get("/volumes") do
      {:ok, %{"Volumes" => volumes}} when is_list(volumes) ->
        {:ok, Enum.map(volumes, &parse_volume/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_network(net) do
    %{
      name: net["Name"] || "",
      driver: net["Driver"] || "",
      labels: net["Labels"] || %{}
    }
  end

  defp parse_volume(vol) do
    %{
      name: vol["Name"] || "",
      driver: vol["Driver"] || "",
      labels: vol["Labels"] || %{}
    }
  end

  # Connects the workload container to its extra networks. Only a ROUTED tier
  # (`traefik.enable=true`, i.e. the web) is attached to the shared INGRESS network
  # so Traefik can reach it; `:service` datastores are deliberately NOT joined to
  # ingress — they live on the private app network only and are never publicly
  # reachable. (Cross-app sharing of a datastore is done by multi-homing it onto
  # the consuming app's network, not by parking it on the ingress mesh.)
  defp maybe_connect_routing_network(container_id, spec) do
    bridge_networks = Map.get(spec, :bridge_networks, [])

    Enum.each(bridge_networks, fn net ->
      ensure_network(net)
      Client.post("/networks/#{net}/connect", %{"Container" => container_id})
    end)

    if spec.labels["traefik.enable"] == "true" do
      ensure_network(@routing_network)
      Client.post("/networks/#{@routing_network}/connect", %{"Container" => container_id})
    end
  end

  @impl true
  def publish(network) do
    ensure_network(network)
    Homelab.Infrastructure.connect_traefik_to_network(network)
  end

  @impl true
  def unpublish(network) do
    Homelab.Infrastructure.disconnect_traefik_from_network(network)
  end

  # --- Image Management ---

  # Images built in the Workbench live only in the local image store and have no
  # registry to pull from, so skip the pull for the local-build namespace.
  defp pull_image("homelab-built/" <> _ = image) do
    require Logger
    Logger.info("[DockerEngine] Using locally-built image #{image} (skipping pull)")
    :ok
  end

  defp pull_image(image) do
    require Logger
    Logger.info("[DockerEngine] Pulling image #{image}...")

    opts = Homelab.Docker.RegistryAuth.request_opts(image)

    case Client.post_stream("/images/create?fromImage=#{URI.encode(image)}", opts) do
      :ok ->
        Logger.info("[DockerEngine] Image #{image} pulled successfully")
        :ok

      {:error, reason} ->
        # A pull failure is not fatal if the daemon already holds the image. An ADOPTED
        # container is by definition running its image, and for any stack that builds its
        # own there is no registry to pull it from -- so failing here rolled the cutover
        # back on an image that was sitting in the local store the whole time.
        if Homelab.Docker.Image.present?(image) do
          Logger.warning(
            "[DockerEngine] Could not pull #{image} (#{inspect(reason)}) — using the local image"
          )

          :ok
        else
          Logger.error("[DockerEngine] Failed to pull image #{image}: #{inspect(reason)}")
          {:error, {:pull_failed, image, reason}}
        end
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

    payload
    |> maybe_put_exposed_ports(exposed_ports)
    |> maybe_put_healthcheck(Map.get(spec, :health_check))
    |> maybe_put_user(Map.get(spec, :user))
    |> maybe_put_gpu(Map.get(spec, :gpu))
    |> maybe_put_aliases(spec)
    |> maybe_put_list("Cmd", Map.get(spec, :command))
    |> maybe_put_list("Entrypoint", Map.get(spec, :entrypoint))
  end

  # nil = let the image's own default apply. Adoption sets these to what the ORIGINAL
  # container ran, which a compose file routinely overrides.
  defp maybe_put_list(payload, _key, nil), do: payload
  defp maybe_put_list(payload, _key, []), do: payload
  defp maybe_put_list(payload, key, value) when is_list(value), do: Map.put(payload, key, value)
  defp maybe_put_list(payload, _key, _value), do: payload

  # NetworkMode alone gives the container exactly one name on the network: its own. An
  # adopted container is RENAMED, so its siblings — which reach it by its compose service
  # name — lose it. Aliases are how it keeps answering to what the rest of the stack calls
  # it. They must be set at CREATE time: attaching them later means a window in which the
  # stack's DNS is broken.
  defp maybe_put_aliases(payload, spec) do
    case Map.get(spec, :network_aliases, []) do
      [] ->
        payload

      aliases ->
        Map.put(payload, "NetworkingConfig", %{
          "EndpointsConfig" => %{
            spec.network => %{"Aliases" => aliases}
          }
        })
    end
  end

  # The Engine can pass a device straight through -- the one thing Swarm cannot do at
  # all. The two vendors take entirely different routes to it.
  defp maybe_put_gpu(payload, nil), do: payload

  # NVIDIA goes through the container toolkit's device-request negotiation rather than
  # a raw device node: the driver injects the libraries and the /dev/nvidia* nodes that
  # match the requested capability. `Count: -1` is the API's "every GPU".
  defp maybe_put_gpu(payload, %{vendor: "nvidia"} = gpu) do
    request =
      if GpuSpec.specific_devices?(gpu) do
        %{"Driver" => "nvidia", "DeviceIDs" => GpuSpec.device_ids(gpu)}
      else
        %{"Driver" => "nvidia", "Count" => -1}
      end

    put_in_host_config(payload, "DeviceRequests", [
      Map.put(request, "Capabilities", [["gpu"]])
    ])
  end

  # AMD/ROCm needs no toolkit: the GPU is reachable as two plain device nodes. /dev/kfd
  # is the compute interface and /dev/dri holds the render nodes; ROCm needs BOTH, and a
  # container with only one of them fails in a way that looks like a driver bug.
  #
  # `devices` cannot narrow this on the Engine -- /dev/dri is a directory and passing it
  # passes every render node in it. Narrowing is left to AMD_VISIBLE_DEVICES (set on the
  # spec's env), which the AMD container runtime honors when it is installed. Without
  # that runtime the container simply sees every GPU, which is the documented ROCm
  # behaviour and not something we should pretend to have prevented.
  defp maybe_put_gpu(payload, %{vendor: "amd"}) do
    devices =
      Enum.map(["/dev/kfd", "/dev/dri"], fn path ->
        %{"PathOnHost" => path, "PathInContainer" => path, "CgroupPermissions" => "rwm"}
      end)

    payload
    |> put_in_host_config("Devices", devices)
    # Without membership of the video/render groups the device nodes are present but
    # unreadable, and ROCm reports "no permission" rather than "no device".
    |> put_in_host_config("GroupAdd", ["video", "render"])
  end

  defp maybe_put_gpu(payload, _gpu), do: payload

  defp put_in_host_config(payload, key, value) do
    Map.update!(payload, "HostConfig", &Map.put(&1, key, value))
  end

  # Preserve an adopted container's uid:gid. Omitted for greenfield deploys so the
  # image's default user applies.
  defp maybe_put_user(payload, user) when is_binary(user) and user != "",
    do: Map.put(payload, "User", user)

  defp maybe_put_user(payload, _user), do: payload

  defp maybe_put_exposed_ports(payload, exposed_ports) when map_size(exposed_ports) > 0 do
    Map.put(payload, "ExposedPorts", exposed_ports)
  end

  defp maybe_put_exposed_ports(payload, _exposed_ports), do: payload

  defp maybe_put_healthcheck(payload, nil), do: payload

  defp maybe_put_healthcheck(payload, healthcheck) when is_map(healthcheck) do
    Map.put(payload, "Healthcheck", healthcheck)
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

  defp ensure_network(network_name), do: Network.ensure_for_workload(network_name)

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
      health: parse_health_string(container["Status"]),
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
      health: parse_health_status(get_in(state, ["Health", "Status"])),
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

  # `/containers/json` reports health inside the human-readable Status string,
  # e.g. "Up 2 minutes (healthy)". `:none` means no healthcheck is defined.
  defp parse_health_string(status) when is_binary(status) do
    cond do
      String.contains?(status, "(healthy)") -> :healthy
      String.contains?(status, "(unhealthy)") -> :unhealthy
      String.contains?(status, "(health: starting)") -> :starting
      true -> :none
    end
  end

  defp parse_health_string(_), do: :none

  defp parse_health_status("healthy"), do: :healthy
  defp parse_health_status("unhealthy"), do: :unhealthy
  defp parse_health_status("starting"), do: :starting
  defp parse_health_status(_), do: :none

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
