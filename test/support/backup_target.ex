defmodule Homelab.BackupTarget do
  @moduledoc """
  Points a test at a real local-disk backup destination in a temporary directory.

  Tests used to drive a Mox stub standing in for the backup provider, which proved the
  context called *something* and nothing about whether a backup could be taken. Running
  the real archive engine against a real directory costs a few milliseconds and covers
  the thing that actually matters.
  """

  alias Homelab.Backups.Keys
  alias Homelab.Backups.TargetConfig
  alias Homelab.Deployments.PermanentHome
  alias Homelab.Settings

  import ExUnit.Callbacks, only: [on_exit: 1]

  @doc """
  Configures a local-disk destination, a managed root and a recovery key.

  Returns the paths so a test can seed data or inspect what was written.
  """
  def configure_local(opts \\ []) do
    base = Path.join(System.tmp_dir!(), "hiab-bt-#{System.unique_integer([:positive])}")
    secrets = Path.join(base, "secrets")
    root = Path.join(base, "backups")
    managed = Path.join(base, "managed")

    File.mkdir_p!(secrets)
    File.mkdir_p!(root)
    File.mkdir_p!(managed)

    previous_secrets = System.get_env("HOMELAB_SECRETS_DIR")
    previous_managed = Application.get_env(:homelab, :managed_root)

    System.put_env("HOMELAB_SECRETS_DIR", secrets)
    Application.put_env(:homelab, :managed_root, managed)

    keys = TargetConfig.settings_keys()
    Settings.set(keys.kind, "local_disk", category: "backups")
    Settings.set(keys.root, root, category: "backups")
    Settings.set(keys.compression, Keyword.get(opts, :compression, "none"), category: "backups")

    Keys.ensure!()

    on_exit(fn ->
      if previous_secrets,
        do: System.put_env("HOMELAB_SECRETS_DIR", previous_secrets),
        else: System.delete_env("HOMELAB_SECRETS_DIR")

      if previous_managed,
        do: Application.put_env(:homelab, :managed_root, previous_managed),
        else: Application.delete_env(:homelab, :managed_root)

      for key <- [keys.kind, keys.root, keys.compression], do: Settings.evict(key)
      File.rm_rf(base)
    end)

    %{base: base, secrets: secrets, backup_root: root, managed_root: managed}
  end

  @doc "Removes the destination so a backup has nowhere configured to go."
  def unconfigure do
    keys = TargetConfig.settings_keys()

    for key <- [keys.kind, keys.root] do
      Settings.delete(key)
      Settings.evict(key)
    end

    :ok
  end

  @doc "Writes files into a service's managed directory, the way a container would."
  def seed_service!(slug, files) do
    dir = PermanentHome.service_dir(slug)
    File.mkdir_p!(dir)

    for {name, contents} <- files do
      path = Path.join(dir, name)
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, contents)
    end

    dir
  end
end
