defmodule Homelab.Deployments.PermanentHome do
  @moduledoc """
  Maps an adopted mount to its **permanent home**: a plane-managed Docker named
  volume whose bytes physically live in a directory on a disk you choose.

  The volume is created with the `local` driver and `type=none, o=bind,
  device=<dir>` options, so the same data is BOTH a named volume the plane owns
  (referenced by name in container specs) AND a plain directory under the managed
  root — which can be backed up off-box (e.g. rsync to the NAS) like any folder.

  The managed root (`config :homelab, :managed_root`) should be on a local disk
  with headroom; the prod default is `/home/austinkregel/homelab-managed` (the
  2.6 TB `/dev/sda2`). Live database data must NOT live on a network mount —
  network FS is for backups, not for running DBs.

  Migration writes the verified copy INTO `backing_dir/2`; the managed container
  then mounts `volume_name/2`, which resolves to those same bytes.
  """

  @behaviour Homelab.Deployments.Migrate.VolumeRegistrar

  alias Homelab.Docker.Client

  @managed_root_default "/home/austinkregel/homelab-managed"

  @doc """
  The disk root where managed volumes physically live. Resolution order: a UI
  override (Settings `managed_root`, read cache-only), then the
  `HOMELAB_MANAGED_ROOT` env var (via app config), then the built-in default.
  """
  def managed_root do
    Homelab.Settings.get_cached("managed_root") ||
      Application.get_env(:homelab, :managed_root) ||
      @managed_root_default
  end

  @doc "The host directory that backs an adopted mount's managed volume."
  def backing_dir(service, container_path) do
    Path.join([managed_root(), slug(service), slug(container_path)])
  end

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
