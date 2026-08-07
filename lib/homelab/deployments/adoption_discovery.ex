defmodule Homelab.Deployments.AdoptionDiscovery do
  @moduledoc """
  Reads the truth from the running Docker daemon for adoption.

  For each existing container it captures exactly what the adoption saga needs to
  reattach a NEW managed container to the SAME underlying data without copying:
  every mount with its real `Source`/volume `Name` (anonymous-volume ids pinned
  verbatim — recomputing them would orphan and then prune real data), the
  `Config.User` (UID/GID must be preserved, never chowned), and the
  `HostConfig.RestartPolicy` (which must be disabled before a single-writer
  cutover so the daemon can't resurrect the old container into a double-writer).

  Each mount is stamped with its `Homelab.Deployments.AdoptionPolicy` tier so
  downstream steps know whether the backup-first gate applies.

  `capture/1` is a pure function over a raw `GET /containers/{id}/json` body, so
  it is unit-testable without a daemon. `discover/0` and `inspect_container/1`
  hit the live socket via `Homelab.Docker.Client`.
  """

  alias Homelab.Docker.Client
  alias Homelab.Deployments.AdoptionPolicy
  alias Homelab.Deployments.RuntimeSpec

  @anonymous_volume_re ~r/^[0-9a-f]{64}$/

  @type mount :: %{
          type: String.t(),
          source: String.t() | nil,
          target: String.t() | nil,
          rw: boolean(),
          anonymous: boolean(),
          mountpoint: String.t() | nil,
          tier: AdoptionPolicy.tier(),
          reset_on_update: boolean()
        }

  @type capture :: %{
          id: String.t() | nil,
          name: String.t(),
          image: String.t() | nil,
          state: String.t() | nil,
          user: String.t() | nil,
          restart_policy: String.t() | nil,
          managed: boolean(),
          compose_project: String.t() | nil,
          compose_service: String.t() | nil,
          command: [String.t()] | nil,
          entrypoint: [String.t()] | nil,
          aliases: [String.t()],
          host_network: boolean(),
          in_scope: boolean(),
          mounts: [mount()],
          capabilities_add: [String.t()],
          capabilities_drop: [String.t()],
          devices: [map()],
          sysctls: map()
        }

  @doc """
  Inspects and captures every container on the daemon (running and stopped).
  Returns `{:ok, [capture]}` or `{:error, reason}`.
  """
  def discover do
    with {:ok, list} when is_list(list) <- Client.get("/containers/json?all=true") do
      captures =
        list
        |> Enum.map(& &1["Id"])
        |> Enum.map(&inspect_container/1)
        |> Enum.flat_map(fn
          {:ok, cap} -> [cap]
          _ -> []
        end)
        |> expand_compose_scope()

      {:ok, captures}
    end
  end

  @doc """
  Promotes the compose SIBLINGS of any in-scope container into scope.

  Scope is otherwise decided per-container, by "does it have a bind under the adoption
  root". That is a fine test for the anchor of a stack, and a terrible one for the rest
  of it: a compose stack's data services routinely have no bind at all — Sail's redis,
  minio and meilisearch keep everything in named volumes, and mailpit keeps nothing.

  Adopting only the containers that happen to hold a bind therefore HALF-adopts the
  stack, which is worse than not adopting it. The adopted half moves onto the plane's
  network, the other half stays on the compose network, and the app loses every sibling
  it reaches by service name.

  `com.docker.compose.project` is the precise, first-class statement that these
  containers are one stack. If any member of a project is in scope, they all are — and
  their mounts are re-tiered accordingly, since a sibling cannot derive its own verdict
  from its own (bind-less) mounts.
  """
  def expand_compose_scope(captures) when is_list(captures) do
    anchors =
      captures
      |> Enum.filter(& &1.in_scope)
      |> Enum.map(& &1.compose_project)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(captures, fn capture ->
      cond do
        capture.in_scope -> capture
        capture.managed -> capture
        is_nil(capture.compose_project) -> capture
        not MapSet.member?(anchors, capture.compose_project) -> capture
        true -> promote(capture)
      end
    end)
  end

  defp promote(capture) do
    mounts =
      Enum.map(capture.mounts, fn m ->
        Map.merge(m, AdoptionPolicy.tier_for(capture.name, m, true))
      end)

    %{capture | in_scope: true, mounts: mounts}
  end

  @doc "Captures only the in-scope (adoptable) containers."
  def discover_in_scope do
    with {:ok, all} <- discover(), do: {:ok, Enum.filter(all, & &1.in_scope)}
  end

  @doc "Inspects one container by id or name and returns `{:ok, capture}`."
  def inspect_container(id_or_name) do
    with {:ok, body} when is_map(body) <- Client.get("/containers/#{id_or_name}/json") do
      {:ok, capture(body)}
    end
  end

  @doc """
  Pure transform of a raw Docker inspect map into a `capture`. No I/O.
  """
  @spec capture(map()) :: capture()
  def capture(inspect) when is_map(inspect) do
    name = inspect |> Map.get("Name", "") |> String.trim_leading("/")
    config = Map.get(inspect, "Config", %{}) || %{}
    host_config = Map.get(inspect, "HostConfig", %{}) || %{}

    # An ADOPTED container keeps the original's name and the original's binds, so the
    # only thing separating it from the container it replaced is the label we stamped
    # on it. Without reading these, every adopted service would be offered for adoption
    # again on the next scan -- and re-adopting it would quiesce and cut over a container
    # the plane is itself running.
    labels = Map.get(config, "Labels") || %{}

    mounts = inspect |> Map.get("Mounts", []) |> Enum.map(&normalize_mount/1)
    in_scope = AdoptionPolicy.service_in_scope?(name, mounts, labels)

    classified =
      Enum.map(mounts, fn m ->
        Map.merge(m, AdoptionPolicy.classify_mount(name, m, mounts, labels))
      end)

    %{
      id: Map.get(inspect, "Id"),
      name: name,
      image: Map.get(config, "Image"),
      state: inspect |> Map.get("State", %{}) |> Map.get("Status"),
      user: blank_to_nil(Map.get(config, "User")),
      restart_policy: host_config |> Map.get("RestartPolicy", %{}) |> Map.get("Name"),
      managed: AdoptionPolicy.already_managed?(labels),
      # The stack this container belongs to, and the name its SIBLINGS reach it by.
      # `compose_service` is the load-bearing one: an app's config says `DB_HOST=mysql`,
      # not `DB_HOST=marketplace-mysql-1`. Adopting a container renames it, so without
      # carrying this through as a network alias the stack loses its own DNS.
      compose_project: blank_to_nil(Map.get(labels, "com.docker.compose.project")),
      compose_service: blank_to_nil(Map.get(labels, "com.docker.compose.service")),
      # WHAT THE KERNEL LET IT DO. Read from the same `HostConfig` the restart policy and
      # network mode come from, and dropped for exactly as long as nobody asked it for.
      #
      # A tunnel container needs NET_ADMIN and `/dev/net/tun` to bring its interface up;
      # a Zigbee bridge needs its USB device; gluetun needs `src_valid_mark` or policy
      # routing breaks. Without these the replacement comes up stripped, and gluetun fails
      # CLOSED — so an adopted VPN takes every app in its namespace offline with it, while
      # the import reports success and nothing says why.
      #
      # `ComposeParser` captured all four from the compose file. Importing the same stack
      # from its RUNNING containers dropped them: the capability existed, on one producer.
      capabilities_add: RuntimeSpec.parse_capabilities(Map.get(host_config, "CapAdd")),
      capabilities_drop: RuntimeSpec.parse_capabilities(Map.get(host_config, "CapDrop")),
      devices: capture_devices(host_config),
      # `Sysctls` is already `%{"name" => "value"}` on an inspect; normalize for the blank
      # and nil cases rather than trusting the daemon's shape.
      sysctls: RuntimeSpec.parse_sysctls(Map.get(host_config, "Sysctls")),
      aliases: network_aliases(inspect, labels, name),
      # What the container actually RUNS. `Config.Cmd` on an inspect is the EFFECTIVE
      # command — the image's default unless the compose file overrode it — so capturing
      # it verbatim reproduces the original either way.
      #
      # Not capturing it is not a loud failure. minio's `command: minio server ...` is
      # overridden, and the image default exits immediately (caught). redis's
      # `--requirepass` is overridden, and the image default comes up FINE — as an
      # unauthenticated redis, reported as a successful adoption.
      command: empty_to_nil(Map.get(config, "Cmd")),
      entrypoint: empty_to_nil(Map.get(config, "Entrypoint")),
      # WHEN it is ready, as opposed to merely started. Dropped, the replacement declares
      # no healthcheck, and everything that gates on readiness silently weakens to "the
      # process exists".
      #
      # That gap is the whole point of a netns donor. `Adoption.donor_barrier/1` holds a
      # child's cutover behind `AwaitHealth` on the donor — but with no declared
      # healthcheck that step passes on `state == :running`, which for gluetun is true the
      # instant the process starts and some tens of seconds before the tunnel is up. The
      # barrier is there, correctly placed, and it was releasing early because the signal
      # it needed had been thrown away one layer down.
      health_check: capture_health_check(config),
      # HOW it was reached, not just what it ran. A container on the host's network
      # publishes no port bindings at all, so the port import has nothing to read: adopting
      # one as a :host deployment produced a replacement on a private bridge, reachable on
      # nothing, and the discovery traffic it existed for (mDNS/SSDP) silently stopped.
      host_network: Map.get(host_config, "NetworkMode") == "host",
      # A container that lives in ANOTHER container's namespace — `network_mode:
      # service:gluetun` in the compose file it came from. Captured as the donor's
      # container id, which the planner resolves to whichever deployment is adopting
      # that container.
      #
      # Not capturing it is silent and severe: the replacement comes up on the tenant
      # network instead, which for the apps people put behind a VPN means every packet
      # that used to go through the tunnel now goes straight out. It adopts "successfully"
      # and leaks from the first second.
      netns_parent_container_id: netns_parent_id(host_config),
      in_scope: in_scope,
      mounts: classified
    }
  end

  # Docker's `Config.Healthcheck` into the canonical map `SpecBuilder.build_health_check/2`
  # reads. `Config` on a CONTAINER inspect is the effective config, so an image-level
  # HEALTHCHECK is reported here even though the compose file never mentioned one — which
  # is exactly the gluetun case.
  #
  # Durations arrive in NANOSECONDS and the canonical map is in seconds; `build_health_check/2`
  # multiplies them back up, so capturing them raw would inflate a 30s interval into 950
  # years and the probe would never run a second time.
  #
  # `["NONE"]` is Docker's explicit "this image has a healthcheck and I do not want it".
  # Capturing that verbatim would emit a literal `NONE` command that fails every probe;
  # honouring it as "no healthcheck" reproduces what the original actually did.
  defp capture_health_check(config) do
    case Map.get(config, "Healthcheck") do
      %{"Test" => test} = hc when is_list(test) and test != [] and test != ["NONE"] ->
        %{
          "test" => test,
          "interval" => ns_to_seconds(Map.get(hc, "Interval"), 30),
          "timeout" => ns_to_seconds(Map.get(hc, "Timeout"), 10),
          "retries" => Map.get(hc, "Retries") || 3,
          "start_period" => ns_to_seconds(Map.get(hc, "StartPeriod"), 10)
        }

      _ ->
        %{}
    end
  end

  # Docker reports 0 for "unset, use the daemon default" rather than omitting the key, and
  # a 0-second interval is not a value this can pass on.
  defp ns_to_seconds(ns, _default) when is_integer(ns) and ns > 0,
    do: max(div(ns, 1_000_000_000), 1)

  defp ns_to_seconds(_ns, default), do: default

  defp netns_parent_id(host_config) do
    case Map.get(host_config, "NetworkMode") do
      "container:" <> id when id != "" -> id
      _ -> nil
    end
  end

  # Every name this container answers to on its current networks, so the managed
  # replacement can answer to them too. Docker's own endpoint aliases first (compose sets
  # the service name there), then the compose service label, then the container name.
  defp network_aliases(inspect, labels, name) do
    endpoint_aliases =
      inspect
      |> Map.get("NetworkSettings", %{})
      |> Kernel.||(%{})
      |> Map.get("Networks", %{})
      |> Kernel.||(%{})
      |> Enum.flat_map(fn {_net, cfg} -> (is_map(cfg) && Map.get(cfg, "Aliases")) || [] end)

    [Map.get(labels, "com.docker.compose.service"), name]
    |> Enum.concat(endpoint_aliases)
    |> Enum.reject(&(is_nil(&1) or &1 == ""))
    # A container's own short id shows up as an alias and is meaningless to a replacement.
    |> Enum.reject(&short_id?(&1, Map.get(inspect, "Id")))
    |> Enum.uniq()
  end

  defp short_id?(alias_name, id) when is_binary(id),
    do: String.starts_with?(id, alias_name) and byte_size(alias_name) >= 8

  defp short_id?(_alias_name, _id), do: false

  # Volume mounts: the adoption "source" is the volume NAME (pinned verbatim,
  # including anonymous hash ids); the host `_data` dir is kept as `mountpoint`.
  defp normalize_mount(%{"Type" => "volume"} = m) do
    name = m["Name"]

    %{
      type: "volume",
      source: name,
      target: m["Destination"],
      rw: Map.get(m, "RW", true),
      anonymous: anonymous_volume?(name),
      mountpoint: m["Source"]
    }
  end

  # Bind / tmpfs: the source IS the host path.
  defp normalize_mount(%{"Type" => type} = m) do
    %{
      type: type,
      source: m["Source"],
      target: m["Destination"],
      rw: Map.get(m, "RW", true),
      anonymous: false,
      mountpoint: m["Source"]
    }
  end

  defp anonymous_volume?(name) when is_binary(name), do: Regex.match?(@anonymous_volume_re, name)
  defp anonymous_volume?(_), do: false

  defp empty_to_nil([]), do: nil
  defp empty_to_nil(list) when is_list(list), do: list
  defp empty_to_nil(_value), do: nil

  # Docker's inspect names a device's three parts differently from every other producer
  # (`PathOnHost`/`PathInContainer`/`CgroupPermissions` rather than host/container/perms),
  # so translate to the canonical row shape and let `RuntimeSpec` own the normalizing —
  # the same function the compose importer and the deployment form already go through.
  defp capture_devices(host_config) do
    host_config
    |> Map.get("Devices")
    |> List.wrap()
    |> Enum.map(fn device ->
      %{
        "host_path" => Map.get(device, "PathOnHost"),
        "container_path" => Map.get(device, "PathInContainer"),
        "permissions" => Map.get(device, "CgroupPermissions")
      }
    end)
    |> RuntimeSpec.parse_devices()
  end

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value
end
