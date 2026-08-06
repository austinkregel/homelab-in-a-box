defmodule Homelab.Deployments.PermanentHome do
  @moduledoc """
  Maps an adopted mount to its **permanent home**: a plane-managed Docker named
  volume whose bytes physically live in a directory on a disk you choose.

  The volume is created with the `local` driver and `type=none, o=bind,
  device=<dir>` options, so the same data is BOTH a named volume the plane owns
  (referenced by name in container specs) AND a plain directory under the managed
  root — which can be backed up off-box (e.g. rsync to the NAS) like any folder.

  The managed root should be on a local disk with headroom; it is set via
  Settings → Import (or `HOMELAB_MANAGED_ROOT`). Live database data must NOT live
  on a network mount — network FS is for backups, not for running DBs.

  Migration writes the verified copy INTO `backing_dir/2`; the managed container
  then mounts `volume_name/2`, which resolves to those same bytes.
  """

  @behaviour Homelab.Deployments.Migrate.VolumeRegistrar

  alias Homelab.Docker.Client
  alias Homelab.Infrastructure

  @unconfigured_message """
  The managed root is not configured, and this instance is running in a container.

  There is no safe default here. `~/homelab-managed` resolves to `/root/homelab-managed`
  INSIDE this container, and every path the plane hands the daemon is interpreted on the
  HOST — so adopted data would be written to the host's `/root/homelab-managed`: a
  location nobody chose, that no backup covers, and that an operator looking for their
  data will not think to check.

  Set it in Settings -> Import ("Managed root"), or with the HOMELAB_MANAGED_ROOT
  environment variable. It must be an absolute HOST path on a local disk with headroom.
  """

  @doc """
  The disk root where managed volumes physically live, or
  `{:error, :managed_root_unconfigured}` when it is unset on a containerized
  install. Non-raising counterpart of `managed_root/0`, for the UI that has to
  render the problem rather than crash on it.

  Resolution order: a UI override (Settings `managed_root`, read cache-only),
  then the `HOMELAB_MANAGED_ROOT` env var (via app config), then — only when the
  plane is NOT containerized — a runtime default of `~/homelab-managed`.
  """
  def fetch_managed_root do
    configured =
      Homelab.Settings.get_cached("managed_root") ||
        Application.get_env(:homelab, :managed_root)

    cond do
      is_binary(configured) and configured != "" ->
        {:ok, configured}

      # `System.user_home()` is a statement about the machine the code runs on. On a
      # containerized install that machine is the container, and the resulting path is
      # then applied by the daemon to the HOST. The two are unrelated directories that
      # happen to share a name, which is exactly why this cannot be a fallback.
      Infrastructure.containerized?() ->
        {:error, :managed_root_unconfigured}

      true ->
        {:ok, Path.join(System.user_home() || "/root", "homelab-managed")}
    end
  end

  @doc """
  The disk root where managed volumes physically live.

  Raises when it is unconfigured on a containerized install rather than falling
  back to a container-local path — see `@unconfigured_message`. Everything that
  WRITES adopted bytes (`backing_dir/2`, `service_dir/1`, the backup restore
  target) goes through here, so the refusal lands before the first byte moves.
  """
  def managed_root do
    case fetch_managed_root() do
      {:ok, root} -> root
      {:error, :managed_root_unconfigured} -> raise ArgumentError, @unconfigured_message
    end
  end

  @doc "The operator-facing explanation of an unconfigured managed root."
  def unconfigured_message, do: @unconfigured_message

  @doc "The host directory that backs an adopted mount's managed volume."
  def backing_dir(service, container_path) do
    Path.join([managed_root(), slug(service), slug(container_path)])
  end

  @doc """
  The host directory holding ALL of a service's managed mounts — the parent of every
  `backing_dir/2` for it.

  This is what a whole-deployment backup covers. `Backups.execute_backup/1` used to
  hardcode `/data/tenants/<tenant>/<app>`, which nothing creates.
  """
  def service_dir(service), do: Path.join(managed_root(), slug(service))

  @doc "The plane-managed named volume for an adopted mount."
  def volume_name(service, container_path) do
    "homelab-managed-#{slug(service)}-#{slug(container_path)}"
  end

  @doc "The `POST /volumes/create` payload for a `device`-bind managed volume."
  def volume_spec(service, container_path) do
    %{
      "Name" => volume_name(service, container_path),
      "Driver" => "local",
      "DriverOpts" => %{
        "type" => "none",
        "o" => "bind",
        "device" => backing_dir(service, container_path)
      },
      "Labels" => %{"homelab.managed" => "true", "homelab.adopted" => "true"}
    }
  end

  @doc """
  Idempotently ensures the managed volume exists (creating it if missing).

  Precondition: `backing_dir/2` must already exist on the host — a `device`-bind
  volume does NOT create its backing directory, and mounting fails if it is
  absent. The migration copy step is what populates that directory; this just
  registers the volume name over it.

  Returns `{:ok, %{name:, device:, created:}}` or `{:error, reason}`.
  """
  @impl true
  def ensure_volume(service, container_path) do
    name = volume_name(service, container_path)
    device = backing_dir(service, container_path)

    case Client.get("/volumes/#{name}") do
      {:ok, _existing} ->
        {:ok, %{name: name, device: device, created: false}}

      {:error, {:not_found, _}} ->
        case Client.post("/volumes/create", volume_spec(service, container_path)) do
          {:ok, _} -> {:ok, %{name: name, device: device, created: true}}
          {:error, reason} -> {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Removes a managed volume (used by the migration step's compensation). Removing
  a `device`-bind volume leaves the underlying directory intact, so this never
  destroys data — it only de-registers the name. Idempotent.
  """
  @impl true
  def remove_volume(name) do
    case Client.delete("/volumes/#{name}") do
      {:ok, _} -> :ok
      {:error, {:not_found, _}} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp slug(value) do
    value
    |> to_string()
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
