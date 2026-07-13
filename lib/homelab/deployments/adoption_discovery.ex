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
          aliases: [String.t()],
          in_scope: boolean(),
          mounts: [mount()]
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
      aliases: network_aliases(inspect, labels, name),
      in_scope: in_scope,
      mounts: classified
    }
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

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(value), do: value
end
