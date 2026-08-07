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

  # The capture reads the kernel privileges off the live container; this is the half that
  # puts them on the replacement. Adopting gluetun without NET_ADMIN and /dev/net/tun
  # produces a VPN that cannot bring its interface up — and because it fails CLOSED,
  # every app in its namespace goes offline with it while the import reports success.
  describe "runtime privileges survive adoption" do
    test "the adopted template carries capabilities, devices and sysctls" do
      review =
        review_fixture(%{
          name: "gluetun",
          image: "qmcgaw/gluetun:latest",
          capabilities_add: ["NET_ADMIN"],
          capabilities_drop: ["ALL"],
          devices: [
            %{
              "host_path" => "/dev/net/tun",
              "container_path" => "/dev/net/tun",
              "permissions" => "rwm"
            }
          ],
          sysctls: %{"net.ipv4.conf.all.src_valid_mark" => "1"}
        })

      plan = AdoptionPlanner.build_plan([review])
      attrs = hd(plan.services).template_attrs

      assert attrs.capabilities_add == ["NET_ADMIN"]
      assert attrs.capabilities_drop == ["ALL"]
      assert attrs.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
      assert [%{"host_path" => "/dev/net/tun"}] = attrs.devices
    end

    # A container granted nothing must not come back with a template asserting it was
    # granted nothing on purpose — but the columns are arrays, and the whole point is
    # that the replacement matches the original, which had none.
    test "a container with no privileges adopts to empty, not to something invented" do
      plan = AdoptionPlanner.build_plan([review_fixture()])
      attrs = hd(plan.services).template_attrs

      assert attrs.capabilities_add == []
      assert attrs.capabilities_drop == []
      assert attrs.devices == []
      assert attrs.sysctls == %{}
    end
  end

  # The barrier that holds a netns child's cutover behind its donor is `AwaitHealth` on
  # the donor deployment (`Adoption.donor_barrier/1`). That step only requires `:healthy`
  # when the template DECLARES a healthcheck; with none it accepts `state == :running`.
  # So dropping the healthcheck here does not merely lose a field — it converts "wait for
  # the VPN to be up" into "wait for the process to exist", and the app in the namespace
  # starts into a tunnel that is still dialling.
  describe "readiness survives adoption" do
    test "the adopted template carries the original's healthcheck" do
      review =
        review_fixture(%{
          name: "gluetun",
          image: "qmcgaw/gluetun:latest",
          health_check: %{
            "test" => ["CMD-SHELL", "/gluetun-entrypoint healthcheck"],
            "interval" => 30,
            "timeout" => 10,
            "retries" => 3,
            "start_period" => 10
          }
        })

      attrs = hd(AdoptionPlanner.build_plan([review]).services).template_attrs

      assert attrs.health_check["test"] == ["CMD-SHELL", "/gluetun-entrypoint healthcheck"]

      assert Homelab.Deployments.SpecBuilder.declares_healthcheck?(attrs.health_check),
             "the adopted template declares no healthcheck, so every readiness gate " <>
               "degrades to 'the process is running'"
    end

    test "a container with no healthcheck adopts to none, not to an invented one" do
      attrs = hd(AdoptionPlanner.build_plan([review_fixture()]).services).template_attrs

      assert attrs.health_check == %{}
      refute Homelab.Deployments.SpecBuilder.declares_healthcheck?(attrs.health_check)
    end
  end

  # An external mount is still MOUNTED — the app needs its media library — it is simply
  # not this plane's data to copy, checksum, or give a permanent home to. Dropping it
  # would be the opposite failure to the one this fixes: a silently crippled app instead
  # of a stalled import.
  describe "external mounts are passed through, never managed" do
    defp external_mount do
      %{source: "/media/Music", target: "/music", type: "bind", tier: :external, rw: true}
    end

    test "the adopted template mounts it at its original host path" do
      plan =
        AdoptionPlanner.build_plan([
          review_fixture(%{name: "navidrome", external: [external_mount()]})
        ])

      volumes = hd(plan.services).template_attrs.volumes
      music = Enum.find(volumes, &(&1["container_path"] == "/music"))

      assert music["source"] == "/media/Music"
      assert music["type"] == "bind"
    end

    # The whole point: no backup gate, no copy, no managed volume for a NAS share.
    test "it is not a migration target, so it is neither backed up nor copied" do
      plan =
        AdoptionPlanner.build_plan([
          review_fixture(%{name: "navidrome", external: [external_mount()]})
        ])

      service = hd(plan.services)

      refute Enum.any?(service.targets, &(&1["container_path"] == "/music"))

      refute Enum.any?(
               service.phase1 ++ service.phase2,
               &(&1.type in [:backup_verify, :migrate_volume] and
                   inspect(&1.resource_handle) =~ "/media/Music")
             )
    end

    # Under :migrate the preserved mounts still get plane-owned volumes; external ones
    # must not be swept along with them.
    test "a preserved mount beside it is still migrated" do
      plan =
        AdoptionPlanner.build_plan([
          review_fixture(%{name: "navidrome", external: [external_mount()]})
        ])

      volumes = hd(plan.services).template_attrs.volumes
      preserved = Enum.find(volumes, &(&1["container_path"] == "/var/lib/postgresql/data"))

      assert preserved["type"] == "volume"
      refute preserved["source"] == "/media/Music"
    end
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

    # The policy was already captured off the live container and then dropped, so an
    # `always` container came back as the platform default of on-failure/3 -- and the
    # operator found out at the next host reboot, when a service that used to come back
    # did not.
    test "the original container's restart policy is carried onto the deployment" do
      plan = AdoptionPlanner.build_plan([review_fixture()])

      [service] = plan.services
      assert service.deployment_attrs == %{restart_policy_override: "always"}
    end

    test "`no` is carried through rather than treated as unset" do
      # A one-shot container that should run once and stay stopped would restart-loop
      # under the platform default.
      plan = AdoptionPlanner.build_plan([review_fixture(%{restart_policy: "no"})])

      [service] = plan.services
      assert service.deployment_attrs == %{restart_policy_override: "no"}
    end

    test "a container with no policy recorded keeps the platform default" do
      plan = AdoptionPlanner.build_plan([review_fixture(%{restart_policy: nil})])

      [service] = plan.services
      assert service.deployment_attrs == %{}
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

    # `to_review/1` builds its map from an EXPLICIT key list, so a captured field that is
    # not named there is dropped. Dropping this one leaves `Adoption` unable to resolve the
    # donor at all: the child is adopted onto the tenant network instead of into the
    # tunnel, leaking every packet from the first second while reporting a successful
    # import. See `Homelab.Deployments.AdoptionNetnsTest`.
    test "carries the container's network namespace parent through to the review" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "abc123"}]}

        "/containers/abc123/json", _opts ->
          {:ok,
           %{
             "Id" => "abc123",
             "Name" => "/homelab-qbittorrent",
             "Config" => %{"Image" => "qbittorrent:latest", "User" => ""},
             "HostConfig" => %{
               "RestartPolicy" => %{"Name" => "always"},
               "NetworkMode" => "container:gluetun-abc"
             },
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/homelab/appdata/qb",
                 "Destination" => "/config",
                 "RW" => true
               }
             ]
           }}
      end)

      assert {:ok, [service]} = AdoptionPlanner.review()
      assert service.netns_parent_container_id == "gluetun-abc"

      # ...and it survives into the plan, where `Adoption` resolves it to a donor.
      plan = AdoptionPlanner.build_plan([service])
      assert [%{netns_parent_container_id: "gluetun-abc"}] = plan.services
    end

    # Same trap, same explicit key list, different field — and this one was live in
    # production: an adopted gluetun came up with no NET_ADMIN and no /dev/net/tun, so it
    # could not initialise iptables, failed CLOSED, and took every app in its namespace
    # offline while the import reported success.
    #
    # Driven through `review/0` rather than a review fixture on purpose. Unit tests either
    # side of `to_review/1` both pass while the field is dropped in the middle, which is
    # exactly how it survived: the capture had it, the planner would have used it, and
    # nothing carried it between them.
    test "carries the container's kernel privileges through to the review and the plan" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "glue1"}]}

        "/containers/glue1/json", _opts ->
          {:ok,
           %{
             "Id" => "glue1",
             "Name" => "/gluetun",
             "Config" => %{"Image" => "qmcgaw/gluetun:latest", "User" => ""},
             "HostConfig" => %{
               "RestartPolicy" => %{"Name" => "always"},
               "CapAdd" => ["NET_ADMIN"],
               "Devices" => [
                 %{
                   "PathOnHost" => "/dev/net/tun",
                   "PathInContainer" => "/dev/net/tun",
                   "CgroupPermissions" => "rwm"
                 }
               ],
               "Sysctls" => %{"net.ipv4.conf.all.src_valid_mark" => "1"}
             },
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/homelab/appdata/gluetun",
                 "Destination" => "/gluetun",
                 "RW" => true
               }
             ]
           }}
      end)

      assert {:ok, [service]} = AdoptionPlanner.review()
      assert service.capabilities_add == ["NET_ADMIN"]
      assert service.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
      assert [%{"host_path" => "/dev/net/tun"}] = service.devices

      plan = AdoptionPlanner.build_plan([service])
      attrs = hd(plan.services).template_attrs

      assert attrs.capabilities_add == ["NET_ADMIN"]
      assert attrs.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
      assert [%{"host_path" => "/dev/net/tun"}] = attrs.devices
    end

    test "a donor is listed above the containers in its namespace" do
      # The daemon listed sabnzbd above the gluetun holding its network, and the apply is
      # sequential and halts on the first failure — so that order read as the CAUSE of a
      # failed import. The list the operator ticks has to match what will happen.
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "sab"}, %{"Id" => "glue"}]}

        "/containers/" <> rest, _opts ->
          id = String.replace_suffix(rest, "/json", "")

          {:ok,
           %{
             "Id" => id,
             "Name" => if(id == "sab", do: "/sabnzbd", else: "/gluetun"),
             "Config" => %{"Image" => "#{id}:latest", "User" => ""},
             "HostConfig" => %{
               "RestartPolicy" => %{"Name" => "always"},
               "NetworkMode" => if(id == "sab", do: "container:glue", else: "some_bridge")
             },
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/homelab/appdata/#{id}",
                 "Destination" => "/config",
                 "RW" => true
               }
             ]
           }}
      end)

      assert {:ok, reviews} = AdoptionPlanner.review()
      assert Enum.map(reviews, & &1.name) == ["gluetun", "sabnzbd"]
    end

    test "a container on its own network carries no namespace parent" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "abc123"}]}

        "/containers/abc123/json", _opts ->
          {:ok,
           %{
             "Id" => "abc123",
             "Name" => "/homelab-postgres",
             "Config" => %{"Image" => "postgres:16.2", "User" => ""},
             "HostConfig" => %{
               "RestartPolicy" => %{"Name" => "always"},
               "NetworkMode" => "some_bridge"
             },
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
      end)

      assert {:ok, [service]} = AdoptionPlanner.review()
      assert service.netns_parent_container_id == nil
    end
  end

  # A stack that is entirely folder mounts should not be forced through a copy it never
  # asked for. :in_place mounts the ORIGINAL directory into the managed container.
  # `rw` was read off the live container and dropped in `volume_entry/3`, so a mount the
  # original could only READ came back writable — the adopted app could delete a media
  # library the original was deliberately fenced out of, and nothing in the UI said so.
  describe "read-only mounts" do
    defp read_only_mount do
      %{preserve_mount() | rw: false, target: "/media", source: "/srv/media"}
    end

    test "a read-only mount is adopted read-only, in place", _ctx do
      plan =
        AdoptionPlanner.build_plan([review_fixture(%{preserve: [read_only_mount()]})],
          strategy: :in_place
        )

      [service] = plan.services
      assert [%{"read_only" => true}] = service.template_attrs.volumes
    end

    test "...and when the data is migrated into a managed volume", _ctx do
      plan = AdoptionPlanner.build_plan([review_fixture(%{preserve: [read_only_mount()]})])

      [service] = plan.services
      assert [%{"read_only" => true}] = service.template_attrs.volumes
    end

    test "a writable mount stays writable" do
      plan = AdoptionPlanner.build_plan([review_fixture()], strategy: :in_place)

      [service] = plan.services
      assert [%{"read_only" => false}] = service.template_attrs.volumes
    end
  end

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
