defmodule Homelab.System.Metrics do
  @moduledoc """
  Collects host system metrics: CPU, memory, disk, and Docker info.
  """

  @doc """
  Collects host metrics. Returns a map with:
  - cpu_percent: float
  - memory_total: int (bytes)
  - memory_used: int (bytes)
  - memory_percent: float
  - disk: list of %{mount: str, total: int, used: int, percent: float}
  - docker: map from Docker.Client.get("/info")
  """
  def collect do
    cpu_percent = collect_cpu()
    {memory_total, memory_used, memory_percent} = collect_memory()
    disk = collect_disk()
    docker = collect_docker_info()

    %{
      cpu_percent: cpu_percent,
      memory_total: memory_total,
      memory_used: memory_used,
      memory_percent: memory_percent,
      disk: disk,
      docker: docker
    }
  end

  defp collect_cpu do
    stat1 = read_proc_stat()
    Process.sleep(100)
    stat2 = read_proc_stat()

    case {stat1, stat2} do
      {%{total: t1, idle: i1}, %{total: t2, idle: i2}} when t2 > t1 ->
        total_delta = t2 - t1
        idle_delta = i2 - i1
        used_delta = total_delta - idle_delta
        used_delta / total_delta * 100

      _ ->
        0.0
    end
  end

  defp read_proc_stat do
    case File.read("/proc/stat") do
      {:ok, content} ->
        [line | _] = String.split(content, "\n")
        parts = String.split(line, ~r/\s+/, trim: true)
        # Skip "cpu" label, then user nice system idle iowait irq softirq steal guest guest_nice
        values = Enum.drop(parts, 1) |> Enum.map(&String.to_integer/1)
        total = Enum.sum(values)
        idle = Enum.at(values, 3) || 0
        %{total: total, idle: idle}

      _ ->
        %{total: 0, idle: 0}
    end
  end

  defp collect_memory do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        lines = String.split(content, "\n")
        mem_total = parse_meminfo_line(lines, "MemTotal")
        mem_available = parse_meminfo_line(lines, "MemAvailable")
        mem_used = mem_total - mem_available
        percent = if mem_total > 0, do: mem_used / mem_total * 100, else: 0.0
        {mem_total, mem_used, percent}

      _ ->
        {0, 0, 0.0}
    end
  end

  defp parse_meminfo_line(lines, key) do
    prefix = key <> ":"
    line = Enum.find(lines, fn l -> String.starts_with?(l, prefix) end)

    case line do
      nil ->
        0

      l ->
        l
        |> String.replace_prefix(prefix, "")
        |> String.trim()
        |> String.split(~r/\s+/)
        |> List.first("0")
        |> String.to_integer()
        |> Kernel.*(1024)
    end
  end

  # Mount-point prefixes that `df` reports but which aren't real physical disks.
  #   * Linux: kernel pseudo-filesystems (/proc/*, /sys/*, devfs at /dev, /run/*).
  #     A container also lists dozens of these, all 0-byte.
  #   * macOS: APFS system plumbing — /System/Volumes/{VM,Preboot,Update,Data,…}
  #     and /private/* firmlink/cryptex mounts. Each is a distinct device sharing
  #     the physical disk, so they can't be de-duplicated away; exclude by path.
  #   * /app/*: the dev source bind-mounts (lib/config/priv/assets). They report
  #     the host drive but aren't disks the operator cares about. Absent in prod
  #     (the release image has no such mounts), so this is a no-op there.
  # What survives is the container/host root plus any disks bind-mounted in by the
  # operator (see HOMELAB_DISKS in build_from_scratch.sh) — the real physical disks.
  @virtual_mount_prefixes ["/proc", "/sys", "/dev", "/run", "/System", "/private", "/app"]

  # Single files that Docker bind-mounts into every container. `df` reports each
  # as a mount carrying the whole host disk's size, so they masquerade as real
  # filesystems. This applies in prod too, since the app runs containerized.
  @injected_file_mounts ["/etc/hostname", "/etc/hosts", "/etc/resolv.conf"]

  defp collect_disk do
    case System.cmd("df", ["-Pk"], stderr_to_stdout: true) do
      {output, 0} -> parse_disk_output(output)
      {_output, _code} -> []
    end
  end

  @doc """
  Parses `df -Pk` output into real-storage entries.

  Public only so it can be unit-tested against captured Linux/macOS/container
  `df` output. Drops pseudo-filesystems, Docker's injected /etc file mounts, and
  zero-capacity rows, then keeps one entry per device (the shortest mount path)
  so a device surfacing under several mounts is counted once.
  """
  def parse_disk_output(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.drop(1)
    |> Enum.reduce([], fn line, acc ->
      case String.split(line, ~r/\s+/, trim: true) do
        [fs, size_str, used_str, _avail, _pct, mount | _] ->
          total = parse_size(size_str) * 1024
          used = parse_size(used_str) * 1024

          if real_filesystem?(mount, total) do
            percent = if total > 0, do: used / total * 100, else: 0.0
            [%{fs: fs, mount: mount, total: total, used: used, percent: percent} | acc]
          else
            acc
          end

        _ ->
          acc
      end
    end)
    |> Enum.reverse()
    |> dedupe_by_device()
  end

  # A mount worth tracking: has real capacity, isn't a pseudo-filesystem, and
  # isn't one of Docker's injected /etc file bind-mounts.
  defp real_filesystem?(mount, total) do
    total > 0 and
      mount not in @injected_file_mounts and
      not String.starts_with?(mount, @virtual_mount_prefixes)
  end

  # The same device can surface under several mount points (bind mounts, the
  # source-mounted /app/* dirs in dev). Keep one entry per device — the one with
  # the shortest, most root-like mount path — so each real volume is counted once.
  defp dedupe_by_device(disks) do
    disks
    |> Enum.group_by(& &1.fs)
    |> Enum.map(fn {_fs, entries} -> Enum.min_by(entries, &String.length(&1.mount)) end)
    |> Enum.map(&Map.delete(&1, :fs))
    |> Enum.sort_by(& &1.mount)
  end

  defp parse_size(str) when is_binary(str) do
    case Integer.parse(str) do
      {n, _} -> n
      :error -> 0
    end
  end

  defp collect_docker_info do
    case Homelab.Docker.Client.get("/info") do
      {:ok, info} when is_map(info) -> info
      _ -> %{}
    end
  end
end
