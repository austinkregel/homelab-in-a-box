defmodule Homelab.Deployments.PermanentHomeTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.PermanentHome

  setup do
    Application.put_env(:homelab, :managed_root, "/home/austinkregel/homelab-managed")
    on_exit(fn -> Application.delete_env(:homelab, :managed_root) end)
    :ok
  end

  test "backing_dir places data under the managed root, slugged" do
    assert PermanentHome.backing_dir("homelab-postgres", "/var/lib/postgresql/data") ==
             "/home/austinkregel/homelab-managed/homelab-postgres/var-lib-postgresql-data"
  end

  test "volume_name is deterministic and docker-safe" do
    assert PermanentHome.volume_name("homelab-postgres", "/var/lib/postgresql/data") ==
             "homelab-managed-homelab-postgres-var-lib-postgresql-data"
  end

  test "different mounts of one service get distinct homes" do
    config = PermanentHome.backing_dir("gitlab", "/etc/gitlab")
    data = PermanentHome.backing_dir("gitlab", "/var/opt/gitlab")
    refute config == data
  end

  test "volume_spec is a device-bind local volume carrying ownership labels" do
    spec = PermanentHome.volume_spec("homelab-mariadb", "/var/lib/mysql")

    assert spec["Driver"] == "local"
    assert spec["DriverOpts"]["o"] == "bind"
    assert spec["DriverOpts"]["type"] == "none"

    assert spec["DriverOpts"]["device"] ==
             "/home/austinkregel/homelab-managed/homelab-mariadb/var-lib-mysql"

    assert spec["Labels"]["homelab.managed"] == "true"
    assert spec["Labels"]["homelab.adopted"] == "true"
  end

  test "managed_root is configurable (e.g. a different disk)" do
    Application.put_env(:homelab, :managed_root, "/mnt/bigdisk/managed")
    assert PermanentHome.backing_dir("plex", "/config") == "/mnt/bigdisk/managed/plex/config"
  end
end
