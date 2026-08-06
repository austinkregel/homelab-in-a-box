defmodule Homelab.Deployments.ReleaseSteps.AdoptVolumeTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.ReleaseSteps.AdoptVolume
  alias Homelab.Deployments.PermanentHome
  alias Homelab.Deployments.{Release, ReleaseStep}

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

    defp test_pid, do: Application.get_env(:homelab, :adopt_volume_test_pid)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "adoptvol-#{System.unique_integer([:positive])}")
    managed_root = Path.join(base, "managed")
    File.mkdir_p!(managed_root)

    Application.put_env(:homelab, :managed_root, managed_root)
    Application.put_env(:homelab, :migrate_volume_registrar, StubRegistrar)
    Application.put_env(:homelab, :adopt_volume_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:homelab, :managed_root)
      Application.delete_env(:homelab, :migrate_volume_registrar)
      Application.delete_env(:homelab, :adopt_volume_test_pid)
      File.rm_rf(base)
    end)

    %{managed_root: managed_root}
  end

  defp target(overrides \\ %{}) do
    Map.merge(
      %{
        "name" => "homelab-postgres",
        "source" => "/whatever",
        "container_path" => "/var/lib/postgresql/data",
        "tier" => "preserve"
      },
      overrides
    )
  end

  defp step(targets), do: %{id: 1, resource_handle: %{"targets" => targets}}

  # The ctx the ReleaseRunner builds: the release with its steps preloaded. The
  # `:migrate_volume` step's recorded handle is the copy engine's own report.
  defp ctx_with_migrated(dests) when is_list(dests) do
    %{
      release: %Release{
        steps: [
          %ReleaseStep{
            type: :migrate_volume,
            status: :completed,
            position: 3,
            resource_handle: %{
              "verified" => true,
              "migrated" =>
                Enum.map(dests, fn dest ->
                  %{"service" => "homelab-postgres", "dest" => dest, "verified" => true}
                end)
            }
          }
        ]
      },
      deployment: nil
    }
  end

  defp ctx_without_migrate do
    %{release: %Release{steps: []}, deployment: nil}
  end

  defp pg_backing_dir, do: PermanentHome.backing_dir("homelab-postgres", "/var/lib/postgresql/data")

  test "registers the managed volume once the copy step reports the home written" do
    assert {:ok, handle} = AdoptVolume.run(step([target()]), ctx_with_migrated([pg_backing_dir()]))
    assert [%{"name" => name, "created" => true}] = handle["volumes"]
    assert_received {:ensure, ^name}
  end

  # The bug this pins. `MigrateCopy` -> `ContainerCopyEngine` creates the permanent
  # home through the DAEMON (a helper container's `HostConfig.Binds`), so the
  # directory exists ON THE HOST. `File.dir?/1` asks the APP container's own
  # filesystem, where that host path does not exist, and aborted adoption on a
  # directory the previous phase had just created and checksummed. Every
  # containerized install failed here; the real one failed with
  # `{:backing_dir_missing, "gluetun", "/root/homelab-managed/gluetun/gluetun"}`.
  test "does not consult the app container's own filesystem for a host path" do
    refute File.dir?(pg_backing_dir()),
           "the host path must NOT exist locally — that is the whole point"

    assert {:ok, handle} = AdoptVolume.run(step([target()]), ctx_with_migrated([pg_backing_dir()]))
    assert [%{"created" => true}] = handle["volumes"]
  end

  # Still fail-closed, and on the condition that actually matters: a permanent home
  # no verified copy ever wrote to. A bare `File.dir?/1` passed here, because Docker
  # auto-creates a `Binds` source — so an empty directory left by any earlier helper
  # container read as "the data is there" and the cutover mounted an empty volume.
  test "fails closed when no verified copy wrote this permanent home" do
    File.mkdir_p!(pg_backing_dir())

    assert {:error, {:copy_unverified, "homelab-postgres", dir}} =
             AdoptVolume.run(step([target()]), ctx_without_migrate())

    assert dir == pg_backing_dir()
    refute_received {:ensure, _}
  end

  # The copy ran, but for a DIFFERENT permanent home — e.g. `managed_root` was
  # edited between phase 1 and phase 2. Registering the volume anyway would point it
  # at a directory the copy never touched.
  test "fails closed when the copy went to a different home than this step would register" do
    assert {:error, {:copy_unverified, "homelab-postgres", _dir}} =
             AdoptVolume.run(step([target()]), ctx_with_migrated(["/somewhere/else"]))

    refute_received {:ensure, _}
  end

  test "compensate de-registers only volumes it created (never bytes)" do
    handle = %{
      resource_handle: %{
        "volumes" => [
          %{"name" => "vol-created", "created" => true},
          %{"name" => "vol-preexisting", "created" => false}
        ]
      }
    }

    assert :ok = AdoptVolume.compensate(handle, %{})
    assert_received {:remove, "vol-created"}
    refute_received {:remove, "vol-preexisting"}
  end
end
