defmodule Homelab.Deployments.AdoptionPlannerTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Deployments.AdoptionPlanner
  alias Homelab.Deployments.PermanentHome

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  defp preserve_mount do
    %{
      type: "bind",
      source: "/home/austinkregel/homelab/appdata/pg",
      target: "/var/lib/postgresql/data",
      mountpoint: "/home/austinkregel/homelab/appdata/pg",
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
      assert target["path"] == "/home/austinkregel/homelab/appdata/pg"
      assert target["source"] == "/home/austinkregel/homelab/appdata/pg"
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
                 "Source" => "/home/austinkregel/homelab/appdata/pg",
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
                 "Source" => "/home/austinkregel/src/app",
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
end
