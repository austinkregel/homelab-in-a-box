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
    with :ok <- pull_image(spec.image, image_source(spec)),
         :ok <- ensure_network(spec.network),
         {:ok, id} <- create_container(spec) do
      attach_then_start(id, spec)
    end
  end

  # Creates the container, replacing one of the same name if it is already there.
  #
  # A name conflict is not an edge case: it is what EVERY redeploy hits, since the
  # previous container for this deployment still holds the name. Both outcomes have to
  # hand back an id the caller treats identically, or the common path and the first-ever
  # deploy drift — which is how the ingress attach came to be correct on one branch and
  # not the other.
  defp create_container(spec) do
    body = build_container_payload(spec)

    case Client.post("/containers/create?name=#{spec.service_name}", body) do
      {:ok, %{"Id" => id}} ->
        {:ok, id}

      {:error, {:conflict, _}} ->
        _ = Client.post("/containers/#{spec.service_name}/stop")
        _ = Client.delete("/containers/#{spec.service_name}?force=true")

        case Client.post("/containers/create?name=#{spec.service_name}", body) do
          {:ok, %{"Id" => id}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Every network is joined BEFORE the container starts. The order is the whole point.
  #
  # `/containers/create` attaches exactly one network — the `NetworkMode` one — so a
  # multi-homed workload has to join the rest through `/networks/<n>/connect`. Those
  # calls used to come AFTER `/containers/<id>/start`, which put a routed container on
  # the network Traefik reads it on only after it was already running.
  #
  # That window is not theoretical and it is not brief enough to ignore. Traefik's docker
  # provider builds its configuration from the container START event: it inspects the
  # container, looks for the network named in `traefik.docker.network`, and when that
  # network is not among the container's yet it falls back to "first available" — the
  # tenant network, which Traefik has no interface on. The later `/connect` is not a
  # container event, so nothing rebuilds the configuration, and the backend address stays
  # wrong until some unrelated container event happens to trigger a rebuild. The symptom
  # is a gateway timeout on an app whose container is healthy and correctly attached, with
  # only a warning in Traefik's log to say so:
  #
  #     Could not find network named "homelab-iab-internal" for container "/<name>".
  #     Defaulting to first available network ("homelab_tenant_<tenant>").
  #
  # A created-but-unstarted container can be connected to a network — the endpoint is
  # recorded and applied when it starts — and Traefik's provider lists RUNNING containers,
  # so it cannot observe the container until every attach is already done. Doing the work
  # here rather than one call later is what makes the race unrepresentable instead of
  # merely unlikely.
  #
  # This is also what the Swarm driver has always done: `build_networks/1` declares the
  # primary, the bridges and ingress together in the service spec, so a Swarm service was
  # never exposed to this. The two drivers now agree.
  defp attach_then_start(id, spec) do
    with :ok <- maybe_connect_routing_network(id, spec),
         {:ok, _} <- Client.post("/containers/#{id}/start") do
      {:ok, id}
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
  #
  # A host-network container is attached to nothing: it has no endpoint of its own, and
  # `/networks/<n>/connect` on it fails outright ("container sharing network namespace
  # with another container or host cannot be connected to any other network"). There is
  # no route to publish for it either, so there is nothing this would accomplish.
  defp maybe_connect_routing_network(_container_id, %{host_network: true}), do: :ok

  # Nor is a container in ANOTHER container's namespace: the daemon rejects
  # `/networks/<n>/connect` on it with the identical error, for the identical reason.
  # Its route is carried by its donor, which IS attached to ingress — see
  # Homelab.Deployments.Netns.
  defp maybe_connect_routing_network(_container_id, %{netns_child: true}), do: :ok

  # Every result here used to be discarded, and `deploy/1` returned `{:ok, id}` regardless.
  # These two calls are the ones that decide whether Traefik can reach the container at
  # all: a routed app that failed to join ingress deployed "successfully", went `:running`,
  # and served 502s with nothing in any log. Same for a gluetun donor that must be
  # multi-homed so its children's routes resolve.
  #
  # Called on a CREATED, not-yet-started container -- see `attach_then_start/2` for why
  # that ordering is load-bearing rather than incidental.
  defp maybe_connect_routing_network(container_id, spec) do
    networks =
      Map.get(spec, :bridge_networks, []) ++
        if spec.labels["traefik.enable"] == "true", do: [@routing_network], else: []

    Enum.reduce_while(networks, :ok, fn net, :ok ->
      with :ok <- ensure_network(net),
           {:ok, _} <- Client.post("/networks/#{net}/connect", %{"Container" => container_id}) do
        {:cont, :ok}
      else
        {:error, reason} -> {:halt, {:error, {:network_attach_failed, net, reason}}}
      end
    end)
  end

  @impl true
  # Attaches the CONTAINER to the given network — the one Traefik resolves its backend
  # on. Idempotent: the daemon answers 403 "already exists in network" when it is
  # already attached, which is success as far as callers are concerned.
  def publish(container_id, network) when is_binary(container_id) and is_binary(network) do
    with :ok <- ensure_network(network),
         {:ok, _} <- Client.post("/networks/#{network}/connect", %{"Container" => container_id}) do
      :ok
    else
      {:error, {:conflict, _}} -> :ok
      {:error, {:http_error, 403, body}} -> already_attached_or_error(container_id, network, body)
      {:error, reason} -> {:error, {:publish_failed, container_id, network, reason}}
    end
  end

  def publish(_container_id, _network), do: :ok

  @impl true
  # Detaching is what actually severs the route: Traefik loses the backend IP and stops
  # routing. `Force` because the container may be running — that is the whole point.
  #
  # Detaches from THIS network only. A routed workload is multi-homed (its private tenant
  # network plus ingress), and severing its public path must not cut it off from its own
  # datastores.
  def unpublish(container_id, network) when is_binary(container_id) and is_binary(network) do
    case Client.post("/networks/#{network}/disconnect", %{
           "Container" => container_id,
           "Force" => true
         }) do
      {:ok, _} -> :ok
      # Not on the network, or the network/container is gone — already severed.
      {:error, {:not_found, _}} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, {:http_error, 403, _}} -> :ok
      {:error, reason} -> {:error, {:unpublish_failed, container_id, network, reason}}
    end
  end

  def unpublish(_container_id, _network), do: :ok

  # 403 on connect means two very different things, and they must not be conflated.
  #
  # "already exists in network" is success. But the daemon also answers 403 for a
  # container sharing another's network namespace, which cannot be attached at all —
  # and swallowing THAT would be the "report success having done nothing" pattern this
  # code exists to avoid. `Deployments.publish_deployment/1` already declines to call
  # this for such a workload; this is the backstop if something else does.
  defp already_attached_or_error(container_id, network, body) do
    if body |> to_string() |> String.downcase() =~ "already exists" do
      :ok
    else
      {:error, {:publish_failed, container_id, network, {:http_error, 403, body}}}
    end
  end

  # --- Image Management ---

  # `MaximumRetryCount` is only meaningful for `on-failure`; the daemon rejects it as
  # invalid alongside any other policy rather than ignoring it.
  defp build_restart_policy(spec) do
    case Map.get(spec, :restart_policy) || "on-failure" do
      "on-failure" -> %{"Name" => "on-failure", "MaximumRetryCount" => 3}
      name -> %{"Name" => name}
    end
  end

  # Whether this spec's image has a registry behind it. A spec that does not say is
  # treated as `:registry` -- fail closed, because the failure mode of guessing
  # `:local` is a deploy that reports success while running the wrong image.
  defp image_source(spec), do: Map.get(spec, :image_source, :registry)

  # Images built in the Workbench live only in the local image store and have no
  # registry to pull from, so skip the pull for the local-build namespace.
  defp pull_image("homelab-built/" <> _ = image, _source) do
    require Logger
    Logger.info("[DockerEngine] Using locally-built image #{image} (skipping pull)")
    :ok
  end

  defp pull_image(image, source) do
    require Logger
    Logger.info("[DockerEngine] Pulling image #{image}...")

    opts = Homelab.Docker.RegistryAuth.request_opts(image)

    case Client.post_stream("/images/create?fromImage=#{URI.encode(image)}", opts) do
      :ok ->
        Logger.info("[DockerEngine] Image #{image} pulled successfully")
        :ok

      {:error, reason} ->
        # Whether a pull failure is survivable is a property of the SPEC, not of what
        # the daemon happens to be holding. An adopted or locally-built image has no
        # registry to be pulled from, so failing there rolls a cutover back on an image
        # the daemon already has. Everything else must come from the registry: falling
        # back would run the old image and report the upgrade as done.
        if source == :local and Homelab.Docker.Image.present?(image) do
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
        "RestartPolicy" => build_restart_policy(spec),
        "Mounts" => mounts,
        "PortBindings" => port_bindings
      }
    }

    payload
    |> maybe_put_exposed_ports(exposed_ports)
    |> maybe_put_healthcheck(Map.get(spec, :health_check))
    |> maybe_put_user(Map.get(spec, :user))
    |> maybe_put_gpu(Map.get(spec, :gpu))
    |> maybe_put_devices(Map.get(spec, :devices))
    |> maybe_put_capabilities(spec)
    |> maybe_put_sysctls(Map.get(spec, :sysctls))
    |> maybe_put_aliases(spec)
    |> maybe_put_list("Cmd", Map.get(spec, :command))
    |> maybe_put_list("Entrypoint", Map.get(spec, :entrypoint))
  end

  # What the container may ask the kernel for. Both lists are sent as-is; RuntimeSpec
  # has already normalized the spelling, so the daemon never sees `NET_ADMIN` and
  # `CAP_NET_ADMIN` as two separate grants of the same permission.
  defp maybe_put_capabilities(payload, spec) do
    payload
    |> put_capability_list("CapAdd", Map.get(spec, :capabilities_add))
    |> put_capability_list("CapDrop", Map.get(spec, :capabilities_drop))
  end

  defp put_capability_list(payload, _key, nil), do: payload
  defp put_capability_list(payload, _key, []), do: payload

  defp put_capability_list(payload, key, caps) when is_list(caps),
    do: put_in_host_config(payload, key, caps)

  defp put_capability_list(payload, _key, _caps), do: payload

  # Docker takes sysctl VALUES as strings and rejects an integer outright, which is
  # why RuntimeSpec stringifies rather than trusting whatever the form posted.
  defp maybe_put_sysctls(payload, sysctls) when is_map(sysctls) and map_size(sysctls) > 0,
    do: put_in_host_config(payload, "Sysctls", sysctls)

  defp maybe_put_sysctls(payload, _sysctls), do: payload

  # Operator-requested device passthrough (/dev/net/tun for a VPN client, a USB dongle
  # for a Zigbee coordinator).
  defp maybe_put_devices(payload, devices) when is_list(devices) and devices != [] do
    append_devices(
      payload,
      Enum.map(devices, fn device ->
        %{
          "PathOnHost" => device["host_path"],
          "PathInContainer" => device["container_path"],
          "CgroupPermissions" => device["permissions"]
        }
      end)
    )
  end

  defp maybe_put_devices(payload, _devices), do: payload

  # `HostConfig.Devices` has TWO producers -- the operator's list and the AMD GPU
  # branch -- and it is a single API key. Writing it with put_in_host_config/3 means
  # whichever runs second silently erases the other: a ROCm workload that also passes
  # a USB dongle would lose /dev/kfd and fail as what looks like a driver bug. Both
  # producers append instead, deduped on the path INSIDE the container (the one Docker
  # actually keys a device on).
  defp append_devices(payload, new_devices) do
    existing = get_in(payload, ["HostConfig", "Devices"]) || []

    put_in_host_config(
      payload,
      "Devices",
      Enum.uniq_by(existing ++ new_devices, & &1["PathInContainer"])
    )
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
  #
  # Not on the host network, though: an alias is a record in a user-defined network's
  # embedded DNS, and the daemon rejects a create carrying one ("network-scoped alias is
  # supported only for containers in user defined networks"). SpecBuilder already drops
  # them for that mode; this makes it unrepresentable rather than merely unbuilt.
  defp maybe_put_aliases(payload, %{host_network: true}), do: payload

  # Same for a container network mode: the daemon rejects a create carrying
  # `NetworkingConfig` alongside it ("conflicting options"), and there is no endpoint to
  # register an alias on anyway. Siblings in one namespace reach each other on
  # `localhost`, not by name.
  defp maybe_put_aliases(payload, %{netns_child: true}), do: payload

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
    # Appends rather than sets: the operator's own devices land in the same API key,
    # and a plain put would silently drop whichever list was written first.
    |> append_devices(devices)
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

  # The `/<proto>` suffix is part of the KEY the daemon matches on, so ExposedPorts and
  # PortBindings must agree on it. A binding under `27900/tcp` for a container listening
  # on 27900/udp is not a partial success — the daemon accepts it, the container starts,
  # and the UDP socket is simply never reachable from off-box. Nothing errors.
  defp build_port_config(ports) when is_list(ports) and length(ports) > 0 do
    exposed =
      ports
      |> Enum.map(fn p -> {port_key(p), %{}} end)
      |> Map.new()

    bindings =
      ports
      |> Enum.map(fn p ->
        {port_key(p), [host_binding(p)]}
      end)
      |> Map.new()

    {exposed, bindings}
  end

  defp build_port_config(_), do: {%{}, %{}}

  # `HostIp` pins the binding to one interface. Omitting it means 0.0.0.0 — every
  # interface — so an adopted `127.0.0.1:5432:5432` database that was deliberately
  # reachable only from the host was silently republished onto the LAN.
  defp host_binding(port) do
    base = %{"HostPort" => to_string(port.external)}

    case Map.get(port, :host_ip) do
      host_ip when is_binary(host_ip) and host_ip != "" -> Map.put(base, "HostIp", host_ip)
      _ -> base
    end
  end

  # Specs built before UDP support carry no :protocol key at all; those ports are TCP.
  defp port_key(p), do: "#{p.internal}/#{Map.get(p, :protocol) || "tcp"}"

  defp build_mounts(volumes) do
    Enum.map(volumes, fn vol ->
      mount = %{
        "Target" => vol.target,
        "Source" => vol.source,
        "Type" => Map.get(vol, :type, "volume"),
        # Omitting this key means read-write to the daemon, which is how a mount the
        # operator had deliberately made `:ro` came back writable after adoption.
        "ReadOnly" => Map.get(vol, :read_only, false)
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
