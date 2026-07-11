defmodule Homelab.System.DockerDisk do
  @moduledoc """
  Docker-managed disk usage, from the Engine's `GET /system/df`.

  A containerized manager can't see the volumes it manages via `df` (they aren't
  mounted into it), but the daemon reports their sizes here. This surfaces
  per-volume usage plus image/container/build-cache totals for the telemetry
  dashboard.

  `/system/df` computes sizes on demand and can be slow on a large host, so this
  is fetched on request (not in the 10s metrics poll) with a generous timeout.
  """

  @receive_timeout 30_000

  @doc """
  Fetches and summarizes Docker disk usage. Returns `{:ok, summary}` or
  `{:error, reason}` when the daemon is unreachable.
  """
  def collect do
    case Homelab.Docker.Client.get("/system/df", receive_timeout: @receive_timeout) do
      {:ok, df} when is_map(df) -> {:ok, parse(df)}
      {:ok, other} -> {:error, {:unexpected_body, other}}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure transform of a `/system/df` response into a usage summary.

  Volumes are the headline (the thing `df` can't see): total size, how many are
  in use, reclaimable bytes (unreferenced volumes), and a size-sorted list.
  """
  def parse(df) when is_map(df) do
    volumes = df |> Map.get("Volumes") |> List.wrap()
    images = df |> Map.get("Images") |> List.wrap()
    containers = df |> Map.get("Containers") |> List.wrap()
    build_cache = df |> Map.get("BuildCache") |> List.wrap()

    volume_items =
      volumes
      |> Enum.map(fn v ->
        usage = Map.get(v, "UsageData") || %{}
        size = int(Map.get(usage, "Size"))
        refs = int(Map.get(usage, "RefCount"))
        %{name: Map.get(v, "Name", "—"), size: size, in_use: refs > 0}
      end)
      # Docker reports Size == -1 when it can't compute a volume's usage; drop
      # those rather than show a negative "disk".
      |> Enum.filter(&(&1.size >= 0))
      |> Enum.sort_by(& &1.size, :desc)

    %{
      volumes: %{
        count: length(volume_items),
        size: sum(volume_items, & &1.size),
        active: Enum.count(volume_items, & &1.in_use),
        reclaimable: volume_items |> Enum.reject(& &1.in_use) |> sum(& &1.size),
        items: volume_items
      },
      images: %{count: length(images), size: sum(images, &int(Map.get(&1, "Size")))},
      containers: %{
        count: length(containers),
        size: sum(containers, &(int(Map.get(&1, "SizeRw")) + int(Map.get(&1, "SizeRootFs"))))
      },
      build_cache: %{size: sum(build_cache, &int(Map.get(&1, "Size")))}
    }
  end

  defp sum(list, fun), do: Enum.reduce(list, 0, fn item, acc -> acc + fun.(item) end)

  defp int(n) when is_integer(n), do: n
  defp int(n) when is_float(n), do: trunc(n)
  defp int(_), do: 0
end
