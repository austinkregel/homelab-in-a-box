defmodule Homelab.Infrastructure.DaemonFacts do
  @moduledoc """
  Read-only facts about the Docker daemon, from `GET /info`.

  This is the whole story for non-Swarm mode, and that is not an oversight. The
  Engine API exposes almost nothing about the daemon that is *writable*: storage
  driver, cgroup driver, live-restore, the default logging driver and the rest all
  come from `/etc/docker/daemon.json` and only take effect when the daemon
  restarts. There is no endpoint to change them, so this module reads them and the
  UI says where the real levers live rather than offering a form that would lie.
  """

  alias Homelab.Docker.Client

  @doc """
  Returns the daemon facts worth putting in front of an operator, or
  `{:error, reason}` if the daemon cannot be reached.
  """
  def load do
    case Client.get("/info") do
      {:ok, info} when is_map(info) -> {:ok, extract(info)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Pure projection of a `/info` body. Separate from `load/0` so the field mapping
  is testable without a daemon.
  """
  def extract(info) when is_map(info) do
    %{
      server_version: Map.get(info, "ServerVersion"),
      storage_driver: Map.get(info, "Driver"),
      cgroup_driver: Map.get(info, "CgroupDriver"),
      cgroup_version: Map.get(info, "CgroupVersion"),
      logging_driver: Map.get(info, "LoggingDriver"),
      # Without live-restore, restarting the daemon (an upgrade, a crash) stops
      # every container on the host. Worth showing precisely because it is the one
      # daemon.json setting whose absence people discover the hard way.
      live_restore: Map.get(info, "LiveRestoreEnabled") == true,
      docker_root_dir: Map.get(info, "DockerRootDir"),
      cpus: Map.get(info, "NCPU"),
      memory_bytes: Map.get(info, "MemTotal"),
      containers: Map.get(info, "Containers"),
      containers_running: Map.get(info, "ContainersRunning"),
      images: Map.get(info, "Images"),
      operating_system: Map.get(info, "OperatingSystem"),
      architecture: Map.get(info, "Architecture"),
      # The daemon's own complaints (no swap limit support, insecure registries,
      # …). These are the closest thing Docker gives you to a health warning.
      warnings: Map.get(info, "Warnings") || []
    }
  end

  def extract(_), do: extract(%{})

  @doc "Human-readable memory total, e.g. `31.3 GB`."
  def format_memory(bytes) when is_integer(bytes) and bytes > 0 do
    gb = bytes / 1_073_741_824
    "#{:erlang.float_to_binary(gb, decimals: 1)} GB"
  end

  def format_memory(_), do: "—"
end
