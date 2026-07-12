defmodule Homelab.Orchestrators.DockerSwarm do
  @moduledoc """
  Docker Swarm implementation of the Orchestrator behaviour.

  Translates orchestrator-agnostic service specs into Docker Swarm API
  calls. All managed services are labeled with `homelab.managed=true`
  for safe identification during reconciliation.
  """

  @behaviour Homelab.Behaviours.Orchestrator

  alias Homelab.Docker.Client
  alias Homelab.Docker.Network
  alias Homelab.Docker.RegistryAuth

  # Must match Homelab.Infrastructure's backbone network (namespaced to avoid
  # colliding with an existing stack's `homelab-internal`).
  @routing_network "homelab-iab-internal"

  @impl true
  def driver_id, do: "docker_swarm"

  @impl true
  def display_name, do: "Docker Swarm"

  @impl true
  def description, do: "Multi-node clustering with built-in load balancing"

  @impl true
  def deploy(spec) do
    # Pull FIRST, then ensure the networks immediately before create — same race
    # DockerEngine.deploy/1 documents: a long image pull leaves a wide window in
    # which a freshly-created (empty) network can be swept by a racing cleanup or
    # prune before anything attaches to it.
    with :ok <- pull_image(spec.image),
         :ok <- ensure_networks(spec) do
      body = build_service_create_payload(spec)

      case Client.post("/services/create", body, registry_auth_opts(spec.image)) do
        {:ok, %{"ID" => id}} -> {:ok, id}
        {:ok, body} when is_map(body) -> {:ok, body["ID"] || body["id"]}
        {:error, {:conflict, _}} -> converge_existing(spec)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # A service by this name already exists — a redeploy, or a re-run of the deploy
  # step. Creating is not the only way to reach the desired state, and bailing out
  # with :already_exists made the step non-idempotent: nothing handled that error, so
  # a redeploy simply failed and the service kept its stale spec (stale labels, stale
  # image). DockerEngine has always converged here by replacing the container; Swarm
  # can do better and roll the new spec onto the existing service in place.
  #
  # Docker accepts a service NAME anywhere it takes an id, so the name from the spec
  # is enough to find it.
  defp converge_existing(spec) do
    require Logger
    Logger.info("[DockerSwarm] Service #{spec.service_name} exists — updating it in place")

    with :ok <- update(spec.service_name, spec),
         {:ok, service} <- Client.get("/services/#{spec.service_name}") do
      {:ok, service["ID"] || service["id"]}
    else
      {:error, reason} -> {:error, reason}
      _ -> {:error, :already_exists}
    end
  end

  # Every network named in the service payload must already exist as an overlay:
  # Swarm will not create one implicitly, and it rejects a local bridge outright
  # ("cannot be used with services"). `build_networks/1` decides which ones the
  # service attaches to, so ensure exactly that set.
  defp ensure_networks(spec) do
    spec
    |> build_networks()
    |> Enum.map(& &1["Target"])
    |> Enum.reduce_while(:ok, fn network, :ok ->
      case Network.ensure_for_workload(network) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # For private (self-hosted registry) images, attach X-Registry-Auth so Swarm
  # distributes the credentials to worker nodes (the `--with-registry-auth`
  # equivalent). Public images get no header.
  defp registry_auth_opts(image), do: RegistryAuth.request_opts(image)

  # Images built in the Workbench live only in the local image store and have no
  # registry to pull from, so skip the pull for the local-build namespace.
  defp pull_image("homelab-built/" <> _ = image) do
    require Logger
    Logger.info("[DockerSwarm] Using locally-built image #{image} (skipping pull)")
    :ok
  end

  defp pull_image(image) do
    require Logger
    Logger.info("[DockerSwarm] Pulling image #{image}...")

    case Client.post_stream(
           "/images/create?fromImage=#{URI.encode(image)}",
           registry_auth_opts(image)
         ) do
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
  def publish(network) do
    Homelab.Infrastructure.connect_traefik_to_network(network)
  end

  @impl true
  def unpublish(network) do
    Homelab.Infrastructure.disconnect_traefik_from_network(network)
  end

  @impl true
  def update(service_id, spec) do
    with {:ok, existing} <- Client.get("/services/#{service_id}"),
         version <- get_in(existing, ["Version", "Index"]) do
      body = build_service_update_payload(spec)

      case Client.post(
             "/services/#{service_id}/update?version=#{version}",
             body,
             registry_auth_opts(spec.image)
           ) do
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

  # --- Payload Builders ---

  defp build_service_create_payload(spec) do
    networks = build_networks(spec)

    %{
      "Name" => spec.service_name,
      "Labels" => spec.labels,
      "UpdateConfig" => build_update_config(spec),
      "TaskTemplate" => %{
        "ContainerSpec" => build_container_spec(spec),
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

  defp build_container_spec(spec) do
    base = %{
      "Image" => spec.image,
      "Env" => env_to_list(spec.env)
    }

    base
    |> maybe_put_user(Map.get(spec, :user))
    |> maybe_put_healthcheck(Map.get(spec, :health_check))
  end

  # Preserve an adopted container's uid:gid; omitted for greenfield deploys.
  defp maybe_put_user(spec, user) when is_binary(user) and user != "",
    do: Map.put(spec, "User", user)

  defp maybe_put_user(spec, _user), do: spec

  defp maybe_put_healthcheck(spec, healthcheck) when is_map(healthcheck),
    do: Map.put(spec, "Healthcheck", healthcheck)

  defp maybe_put_healthcheck(spec, _healthcheck), do: spec

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

  @doc false
  # How Swarm swaps tasks when a service is converged. Docker's default is
  # `stop-first`: kill the old task, then start the new one — so every config save
  # costs a gap even when the image is already pulled.
  #
  # `start-first` runs the new task alongside the old and only retires the old once
  # the new one is up, which with Traefik in front is genuinely zero-downtime. It is
  # NOT a safe blanket default, for two reasons:
  #
  #   * WITHOUT A HEALTHCHECK it is worse than stop-first. Swarm treats a task as
  #     up the moment its process starts, so it would retire the old container while
  #     the new one is still booting, and Traefik would route to something that
  #     cannot serve yet. A short honest gap beats a burst of 502s.
  #
  #   * A DATASTORE must never overlap. Two MariaDB tasks briefly sharing one volume
  #     is corruption, not a rolling update. `:service` deployments always stop first.
  #
  # FailureAction is left at Docker's `pause` deliberately. `rollback` sounds
  # appealing, but Swarm would silently revert to the PREVIOUS spec, the service
  # would go healthy again, and the release saga's AwaitHealth step would see health
  # and report success — a "successful" deploy still running the old code. A paused,
  # visibly-failed update is the honest outcome, and the saga's own compensation is
  # what should decide to roll back.
  def build_update_config(spec) do
    %{
      "Order" => update_order(spec),
      "Parallelism" => 1,
      "FailureAction" => "pause"
    }
  end

  defp update_order(spec) do
    cond do
      Map.get(spec, :service_mode, false) -> "stop-first"
      is_map(Map.get(spec, :health_check)) -> "start-first"
      true -> "stop-first"
    end
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
      health: :none,
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
