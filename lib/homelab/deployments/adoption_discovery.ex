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

      {:ok, captures}
    end
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
      in_scope: in_scope,
      mounts: classified
    }
  end

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
