defmodule Homelab.Deployments.PermanentHomeTest do
  use ExUnit.Case, async: false

  import Mox

  alias Homelab.Deployments.PermanentHome

  setup :verify_on_exit!

  setup do
    Application.put_env(:homelab, :managed_root, "/home/austinkregel/homelab-managed")
    on_exit(fn -> Application.delete_env(:homelab, :managed_root) end)
    # Route this process's Docker client to the mock (no global state mutated).
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  test "managed_root resolves app-config value, then the built-in default" do
    Application.put_env(:homelab, :managed_root, "/mnt/tank/managed")
    Homelab.Settings.evict("managed_root")
    assert PermanentHome.managed_root() == "/mnt/tank/managed"

    Application.delete_env(:homelab, :managed_root)
    assert PermanentHome.managed_root() == "/home/austinkregel/homelab-managed"
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

  describe "ensure_volume/2 (mocked daemon)" do
    test "an existing volume yields created: false and never POSTs" do
      name = PermanentHome.volume_name("homelab-postgres", "/var/lib/postgresql/data")
      device = PermanentHome.backing_dir("homelab-postgres", "/var/lib/postgresql/data")

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path == "/volumes/#{name}"
        {:ok, %{"Name" => name, "Driver" => "local"}}
      end)

      assert {:ok, %{name: ^name, device: ^device, created: false}} =
               PermanentHome.ensure_volume("homelab-postgres", "/var/lib/postgresql/data")
    end

    test "a 404 triggers POST /volumes/create with the device-bind spec and created: true" do
      name = PermanentHome.volume_name("homelab-mariadb", "/var/lib/mysql")
      device = PermanentHome.backing_dir("homelab-mariadb", "/var/lib/mysql")
      expected_spec = PermanentHome.volume_spec("homelab-mariadb", "/var/lib/mysql")

      expect(Homelab.Mocks.DockerClient, :get, fn "/volumes/" <> ^name, _opts ->
        {:error, {:not_found, %{}}}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/volumes/create", body, _opts ->
        assert body == expected_spec
        assert body["Driver"] == "local"
        assert body["DriverOpts"]["o"] == "bind"
        assert body["DriverOpts"]["type"] == "none"
        assert body["DriverOpts"]["device"] == device
        {:ok, %{"Name" => name}}
      end)

      assert {:ok, %{name: ^name, device: ^device, created: true}} =
               PermanentHome.ensure_volume("homelab-mariadb", "/var/lib/mysql")
    end

    test "a 404 followed by a create error propagates the error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/volumes/create", _body, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} =
               PermanentHome.ensure_volume("homelab-mariadb", "/var/lib/mysql")
    end

    test "a non-404 GET error propagates without attempting a create" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} =
               PermanentHome.ensure_volume("homelab-mariadb", "/var/lib/mysql")
    end
  end

  describe "remove_volume/1 (mocked daemon)" do
    test "DELETEs the volume and returns :ok" do
      expect(Homelab.Mocks.DockerClient, :delete, fn "/volumes/homelab-managed-x", _opts ->
        {:ok, %{}}
      end)

      assert :ok = PermanentHome.remove_volume("homelab-managed-x")
    end

    test "treats a 404 as idempotent :ok" do
      expect(Homelab.Mocks.DockerClient, :delete, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert :ok = PermanentHome.remove_volume("already-gone")
    end

    test "propagates a non-404 error" do
      expect(Homelab.Mocks.DockerClient, :delete, fn _path, _opts ->
        {:error, {:http_error, 409, %{}}}
      end)

      assert {:error, {:http_error, 409, %{}}} = PermanentHome.remove_volume("in-use")
    end
  end
end
