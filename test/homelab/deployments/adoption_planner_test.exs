defmodule Homelab.Deployments.AdoptionPlannerTest do
  # async: false — pins the global :adoption_root so scope checks are deterministic.
  use ExUnit.Case, async: false

  import Mox

  alias Homelab.Deployments.AdoptionPlanner
  alias Homelab.Deployments.PermanentHome

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    Application.put_env(:homelab, :adoption_root, "/srv/homelab")
    Homelab.Settings.evict("adoption_root")

    on_exit(fn ->
      Application.delete_env(:homelab, :adoption_root)
      Homelab.Settings.evict("adoption_root")
    end)

    :ok
  end

  defp preserve_mount do
    %{
      type: "bind",
      source: "/srv/homelab/appdata/pg",
      target: "/var/lib/postgresql/data",
      mountpoint: "/srv/homelab/appdata/pg",
      tier: :preserve,
      anonymous: false,
      rw: true,
      reset_on_update: false
    }
  end

  defp review_fixture(overrides \\ %{}) do
    Map.merge(
      %{
        name: "homelab-postgres",
        image: "postgres:16.2",
        user: "999:999",
        restart_policy: "always",
        container_id: "abc123",
        preserve: [preserve_mount()],
        rebuildable: [],
        out_of_scope: []
      },
      overrides
    )
  end

  describe "build_plan/1" do
    test "emits the ordered Phase-1 steps with filesystem-path targets" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      assert Enum.map(plan.phase1, & &1.type) ==
               [:backup_verify, :quiesce_old, :migrate_volume, :resume_old]

      [backup, quiesce, migrate, resume] = plan.phase1

      [target] = backup.resource_handle["targets"]
      assert target["name"] == "homelab-postgres"
      assert target["path"] == "/srv/homelab/appdata/pg"
      assert target["source"] == "/srv/homelab/appdata/pg"
      assert target["container_path"] == "/var/lib/postgresql/data"
      assert target["tier"] == "preserve"

      # migrate_volume reads the same targets shape.
      assert migrate.resource_handle["targets"] == backup.resource_handle["targets"]

      assert quiesce.resource_handle["container"] == "abc123"
      assert resume.resource_handle["container"] == "abc123"
      assert resume.resource_handle["restart_policy"] == "always"
    end

    test "emits the Phase-2 cutover steps with enriched handles" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      assert Enum.map(plan.phase2, & &1.type) ==
               [:adopt_credentials, :adopt_volume, :adopt_container, :verify_integrity]

      [creds, _volume, container, _verify] = plan.phase2
      assert creds.resource_handle["image"] == "postgres:16.2"
      assert creds.resource_handle["container"] == "abc123"

      assert container.resource_handle["container"] == "abc123"
      assert container.resource_handle["restart_policy"] == "always"
      assert is_list(container.resource_handle["targets"])
    end

    test "each service carries its own phase1/phase2 and a host-exposure template" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      [service] = plan.services

      assert Enum.map(service.phase1, & &1.type) ==
               [:backup_verify, :quiesce_old, :migrate_volume, :resume_old]

      assert Enum.map(service.phase2, & &1.type) ==
               [:adopt_credentials, :adopt_volume, :adopt_container, :verify_integrity]

      assert service.template_attrs.exposure_mode == :host
      assert service.template_attrs.description =~ "Adopted from existing container"
    end

    # A container on the host's network publishes NO port bindings, so the port import
    # has nothing to read. Adopting it as :host produced a replacement on a private
    # bridge, reachable on nothing — and silently killed the mDNS/SSDP discovery the
    # original was on the host network for in the first place.
    test "a container that ran on the host's network is adopted onto the host's network" do
      plan = AdoptionPlanner.build_plan([review_fixture(%{host_network: true})])

      [service] = plan.services
      assert service.template_attrs.exposure_mode == :host_network
    end

    test "a container on a bridge network is still adopted with host ports" do
      plan = AdoptionPlanner.build_plan([review_fixture(%{host_network: false})])

      [service] = plan.services
      assert service.template_attrs.exposure_mode == :host
    end

    test "proposes a managed template referencing the permanent-home volume + captured user" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      [service] = plan.services
      attrs = service.template_attrs
      assert attrs.slug == "adopted-homelab-postgres"
      assert attrs.user == "999:999"
      assert attrs.source == "adopted"

      [vol] = attrs.volumes
      assert vol["container_path"] == "/var/lib/postgresql/data"
      assert vol["type"] == "volume"

      assert vol["source"] ==
               PermanentHome.volume_name("homelab-postgres", "/var/lib/postgresql/data")
    end

    test "aggregates steps across multiple selected services" do
      plan =
        AdoptionPlanner.build_plan([
          review_fixture(),
          review_fixture(%{name: "homelab-redis", container_id: "def456"})
        ])

      assert length(plan.services) == 2
      # 4 Phase-1 steps per service.
      assert length(plan.phase1) == 8
      assert length(plan.phase2) == 8
    end
  end

  describe "review/0" do
    test "groups an in-scope container's mounts and skips out-of-scope containers" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "abc123"}, %{"Id" => "xyz789"}]}

        "/containers/abc123/json", _opts ->
          {:ok,
           %{
             "Id" => "abc123",
             "Name" => "/homelab-postgres",
             "Config" => %{"Image" => "postgres:16.2", "User" => "999:999"},
             "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}},
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/homelab/appdata/pg",
                 "Destination" => "/var/lib/postgresql/data",
                 "RW" => true
               }
             ]
           }}

        "/containers/xyz789/json", _opts ->
          {:ok,
           %{
             "Id" => "xyz789",
             "Name" => "/unrelated-dev-thing",
             "Config" => %{"Image" => "node:20", "User" => ""},
             "HostConfig" => %{"RestartPolicy" => %{"Name" => "no"}},
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/other/app",
                 "Destination" => "/app",
                 "RW" => true
               }
             ]
           }}
      end)

      assert {:ok, [service]} = AdoptionPlanner.review()
      assert service.name == "homelab-postgres"
      assert service.user == "999:999"
      assert [mount] = service.preserve
      assert mount.target == "/var/lib/postgresql/data"
      assert service.rebuildable == []
      assert service.out_of_scope == []
    end

    test "propagates a discovery error" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, :boom} end)
      assert {:error, :boom} = AdoptionPlanner.review()
    end
  end

  # A stack that is entirely folder mounts should not be forced through a copy it never
  # asked for. :in_place mounts the ORIGINAL directory into the managed container.
  describe "build_plan/2 with strategy: :in_place" do
    test "the managed container mounts the original folder, not a copy of it" do
      plan = AdoptionPlanner.build_plan([review_fixture()], strategy: :in_place)

      [service] = plan.services
      [volume] = service.template_attrs.volumes

      assert volume["type"] == "bind"
      assert volume["source"] == "/srv/homelab/appdata/pg"
      assert volume["container_path"] == "/var/lib/postgresql/data"

      # And emphatically NOT the permanent-home name the :migrate path would mint.
      refute volume["source"] ==
               PermanentHome.volume_name("homelab-postgres", "/var/lib/postgresql/data")
    end

    test "an existing NAMED volume is referenced by name, also without copying" do
      mount = %{
        preserve_mount()
        | type: "volume",
          source: "pgdata",
          mountpoint: "/var/lib/docker/volumes/pgdata/_data"
      }

      plan =
        AdoptionPlanner.build_plan([review_fixture(%{preserve: [mount]})], strategy: :in_place)

      [service] = plan.services
      [volume] = service.template_attrs.volumes

      assert volume["type"] == "volume"
      assert volume["source"] == "pgdata"
    end

    test "no bytes move: no copy step, and no permanent home to register" do
      plan = AdoptionPlanner.build_plan([review_fixture()], strategy: :in_place)

      # A backup is still PROVEN first — with no second copy, it is the only net.
      assert Enum.map(plan.phase1, & &1.type) == [:backup_verify]

      assert Enum.map(plan.phase2, & &1.type) ==
               [:adopt_credentials, :adopt_container, :verify_integrity]

      refute :migrate_volume in Enum.map(plan.phase1 ++ plan.phase2, & &1.type)
      refute :adopt_volume in Enum.map(plan.phase1 ++ plan.phase2, & &1.type)
    end

    test "targets carry the strategy, so the cutover knows not to re-sync them" do
      plan = AdoptionPlanner.build_plan([review_fixture()], strategy: :in_place)
      [backup] = plan.phase1
      [target] = backup.resource_handle["targets"]

      assert target["strategy"] == "in_place"
      # The real filesystem path, so BackupVerify reads the actual bytes.
      assert target["source"] == "/srv/homelab/appdata/pg"
    end

    # Docker Desktop REPORTS a bind's source as /host_mnt/Users/... but only ACCEPTS
    # /Users/... when creating one. Two things break on the raw value: the backup engine
    # File.cp_r's it from inside our container, where /host_mnt exists nowhere; and the
    # daemon reads it back as a NAME, mounting an empty named volume over the data.
    test "a Docker Desktop /host_mnt path is normalized for both the saga and the mount" do
      mount = %{
        preserve_mount()
        | source: "/host_mnt/srv/homelab/appdata/pg",
          mountpoint: "/host_mnt/srv/homelab/appdata/pg"
      }

      plan =
        AdoptionPlanner.build_plan([review_fixture(%{preserve: [mount]})], strategy: :in_place)

      [service] = plan.services
      [volume] = service.template_attrs.volumes
      [target] = hd(plan.phase1).resource_handle["targets"]

      assert volume["source"] == "/srv/homelab/appdata/pg"
      assert target["source"] == "/srv/homelab/appdata/pg"
      assert target["path"] == "/srv/homelab/appdata/pg"
    end

    test "the managed template keeps the names the rest of the stack calls it by" do
      review = review_fixture(%{aliases: ["mysql", "marketplace-mysql-1"]})
      plan = AdoptionPlanner.build_plan([review], strategy: :in_place)

      [service] = plan.services

      assert service.template_attrs.network_aliases == ["mysql", "marketplace-mysql-1"]
    end

    test ":migrate remains the default and is unchanged" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      assert Enum.map(plan.phase1, & &1.type) ==
               [:backup_verify, :quiesce_old, :migrate_volume, :resume_old]

      [service] = plan.services
      [volume] = service.template_attrs.volumes

      assert volume["type"] == "volume"

      assert volume["source"] ==
               PermanentHome.volume_name("homelab-postgres", "/var/lib/postgresql/data")

      [target] = hd(plan.phase1).resource_handle["targets"]
      assert target["strategy"] == "migrate"
    end
  end
end
