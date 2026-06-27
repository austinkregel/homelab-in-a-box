defmodule Homelab.Deployments.ReleaseSteps.MigrateCopyTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.ReleaseSteps.MigrateCopy
  alias Homelab.Deployments.PermanentHome

  # Stub registrar: records create/remove calls, no daemon needed.
  defmodule StubRegistrar do
    @behaviour Homelab.Deployments.Migrate.VolumeRegistrar

    @impl true
    def ensure_volume(service, container_path) do
      name = PermanentHome.volume_name(service, container_path)
      send(test_pid(), {:ensure, name})

      {:ok,
       %{name: name, device: PermanentHome.backing_dir(service, container_path), created: true}}
    end

    @impl true
    def remove_volume(name) do
      send(test_pid(), {:remove, name})
      :ok
    end

    defp test_pid, do: Application.get_env(:homelab, :migrate_test_pid)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "migratecopy-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    managed_root = Path.join(base, "managed")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "data.txt"), "important")

    Application.put_env(:homelab, :managed_root, managed_root)
    Application.put_env(:homelab, :migrate_volume_registrar, StubRegistrar)
    Application.put_env(:homelab, :migrate_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:homelab, :managed_root)
      Application.delete_env(:homelab, :migrate_volume_registrar)
      Application.delete_env(:homelab, :migrate_test_pid)
      File.rm_rf(base)
    end)

    %{src: src, managed_root: managed_root}
  end

  defp step(targets), do: %{id: 1, resource_handle: %{"targets" => targets}}

  test "migrates a preserve target to its permanent home and registers the volume", %{src: src} do
    s =
      step([
        %{
          "name" => "homelab-postgres",
          "source" => src,
          "container_path" => "/var/lib/postgresql/data",
          "tier" => "preserve"
        }
      ])

    assert {:ok, handle} = MigrateCopy.run(s, %{})
    assert handle["verified"] == true
    assert [entry] = handle["migrated"]

    assert entry["service"] == "homelab-postgres"
    assert entry["files"] == 1
    assert entry["volume"] == "homelab-managed-homelab-postgres-var-lib-postgresql-data"

    # The data physically landed at the backing dir, byte-identical.
    assert File.read!(Path.join(entry["dest"], "data.txt")) == "important"
    assert_received {:ensure, "homelab-managed-homelab-postgres-var-lib-postgresql-data"}
  end

  test "skips non-preserve targets", %{src: src} do
    s =
      step([
        %{
          "name" => "influxdb",
          "source" => src,
          "container_path" => "/v",
          "tier" => "rebuildable"
        },
        %{"name" => "kratos", "source" => src, "container_path" => "/v", "tier" => "out_of_scope"}
      ])

    assert {:ok, %{"migrated" => []}} = MigrateCopy.run(s, %{})
    refute_received {:ensure, _}
  end

  test "is fail-closed when a source is missing" do
    s =
      step([
        %{
          "name" => "gitlab",
          "source" => "/no/such",
          "container_path" => "/d",
          "tier" => "preserve"
        }
      ])

    assert {:error, {:migrate_failed, "gitlab", {:source_missing, _}}} = MigrateCopy.run(s, %{})
  end

  test "compensate removes created volumes and the copies, never the source", %{src: src} do
    s =
      step([
        %{"name" => "pg", "source" => src, "container_path" => "/d", "tier" => "preserve"}
      ])

    {:ok, handle} = MigrateCopy.run(s, %{})
    [entry] = handle["migrated"]
    assert File.exists?(entry["dest"])

    completed = %{id: 1, resource_handle: handle}
    assert :ok = MigrateCopy.compensate(completed, %{})

    assert_received {:remove, _}
    refute File.exists?(entry["dest"])
    # Source is untouched.
    assert File.read!(Path.join(src, "data.txt")) == "important"
  end
end
