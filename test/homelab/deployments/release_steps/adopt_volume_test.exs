defmodule Homelab.Deployments.ReleaseSteps.AdoptVolumeTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.ReleaseSteps.AdoptVolume
  alias Homelab.Deployments.PermanentHome

  defmodule StubRegistrar do
    @behaviour Homelab.Deployments.Migrate.VolumeRegistrar

    @impl true
    def ensure_volume(service, container_path) do
      name = PermanentHome.volume_name(service, container_path)
      send(test_pid(), {:ensure, name})
      {:ok, %{name: name, device: PermanentHome.backing_dir(service, container_path), created: true}}
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

  test "registers the managed volume when the backing dir exists" do
    # Pre-create the permanent-home backing dir (as MigrateCopy would have).
    File.mkdir_p!(PermanentHome.backing_dir("homelab-postgres", "/var/lib/postgresql/data"))

    assert {:ok, handle} = AdoptVolume.run(step([target()]), %{})
    assert [%{"name" => name, "created" => true}] = handle["volumes"]
    assert_received {:ensure, ^name}
  end

  test "fails closed when the backing dir is missing" do
    assert {:error, {:backing_dir_missing, "homelab-postgres", _dir}} =
             AdoptVolume.run(step([target()]), %{})

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
