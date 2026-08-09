defmodule Homelab.StorageTest do
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Storage

  setup do
    Homelab.Settings.evict("storage_mount_roots")
    on_exit(fn -> Homelab.Settings.delete("storage_mount_roots") end)
    :ok
  end

  describe "consumer_index" do
    test "indexes a named volume by the name the deployment gave it" do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "jellyfin", volumes: [])

      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          volumes_override: [
            %{"container_path" => "/config", "type" => "volume", "source" => "jellyfin-config"}
          ]
        )

      index = Storage.consumer_index()

      assert [consumer] = Map.fetch!(index, {"volume", "jellyfin-config"})
      assert consumer.deployment_id == deployment.id
      assert consumer.container_path == "/config"
      assert consumer.tenant == "media"
    end

    # The whole reason SpecBuilder.volume_name/3 is public. A blank source is stored as
    # nil, but the container mounts a derived name -- index it under the stored nil and
    # the volume page reports the app's real volume as unreferenced, which is the one
    # somebody then deletes.
    test "indexes a blank-source volume under the name SpecBuilder will derive" do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "sonarr", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [%{"container_path" => "/config"}]
      )

      index = Storage.consumer_index()

      assert [_] = Map.fetch!(index, {"volume", "homelab-media-sonarr-config"})
    end

    test "indexes a bind by its host path and carries read-only through" do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "plex", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [
          %{
            "container_path" => "/media",
            "type" => "bind",
            "source" => "/mnt/tank/media",
            "read_only" => true
          }
        ]
      )

      assert [consumer] =
               Storage.consumer_index() |> Map.fetch!({"bind", "/mnt/tank/media"})

      assert consumer.read_only
    end

    test "falls back to the template's volumes when there is no override" do
      tenant = insert(:tenant, slug: "media")

      template =
        insert(:app_template,
          slug: "radarr",
          volumes: [%{"container_path" => "/data", "type" => "bind", "source" => "/srv/radarr"}]
        )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: nil
      )

      assert Map.has_key?(Storage.consumer_index(), {"bind", "/srv/radarr"})
    end

    test "two deployments sharing one host path collapse into one entry with two consumers" do
      tenant = insert(:tenant, slug: "media")

      for slug <- ~w(plex jellyfin) do
        template = insert(:app_template, slug: slug, volumes: [])

        insert(:deployment,
          tenant: tenant,
          app_template: template,
          volumes_override: [
            %{"container_path" => "/media", "type" => "bind", "source" => "/mnt/tank/media"}
          ]
        )
      end

      assert [bind] = Storage.binds()
      assert bind.source == "/mnt/tank/media"
      assert length(bind.consumers) == 2
    end
  end

  describe "mount roots" do
    test "the two built-in roots are always listed and are not deletable metadata" do
      roots = Storage.mount_roots()

      assert Enum.all?(roots, & &1.builtin)
      assert Enum.map(roots, & &1.name) == ["Adoption root", "Managed root"]
    end

    test "a registered root round-trips and appends after the built-ins" do
      assert {:ok, _} = Storage.put_mount_root("tank", "/mnt/tank")

      assert %{name: "tank", path: "/mnt/tank", builtin: false} =
               Storage.mount_roots() |> List.last()
    end

    test "a trailing slash is normalized away so prefix matching stays honest" do
      assert {:ok, _} = Storage.put_mount_root("tank", "/mnt/tank/")
      assert [%{path: "/mnt/tank"}] = Storage.custom_roots()
    end

    # A relative root would compose into a relative bind source, which Docker reads as a
    # named volume -- the silent empty mount VolumeSpec exists to refuse.
    test "a relative path is refused" do
      assert {:error, message} = Storage.put_mount_root("tank", "mnt/tank")
      assert message =~ "absolute"
    end

    test "a blank name is refused" do
      assert {:error, _} = Storage.put_mount_root("  ", "/mnt/tank")
    end

    test "a duplicate name is refused rather than shadowing the first" do
      assert {:ok, _} = Storage.put_mount_root("tank", "/mnt/tank")
      assert {:error, message} = Storage.put_mount_root("tank", "/mnt/other")
      assert message =~ "already exists"
      assert [%{path: "/mnt/tank"}] = Storage.custom_roots()
    end

    test "deleting a root forgets only that one" do
      Storage.put_mount_root("tank", "/mnt/tank")
      Storage.put_mount_root("scratch", "/mnt/scratch")

      Storage.delete_mount_root("tank")

      assert [%{name: "scratch"}] = Storage.custom_roots()
    end
  end

  describe "binds" do
    setup do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "plex", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [
          %{"container_path" => "/media", "type" => "bind", "source" => "/mnt/tank/media"}
        ]
      )

      :ok
    end

    # Longest prefix wins, because that is how the kernel resolves it. Reporting `/`
    # would say the data is on the boot disk when it is on the NAS.
    test "a bind resolves to the most specific filesystem containing it" do
      disks = [
        %{mount: "/", total: 100, used: 10, percent: 10.0},
        %{mount: "/mnt/tank", total: 100, used: 50, percent: 50.0}
      ]

      assert [%{disk: %{mount: "/mnt/tank"}}] = Storage.binds(nil, [], disks)
    end

    test "a bind on a filesystem this process cannot see has no disk rather than a wrong one" do
      disks = [%{mount: "/boot", total: 100, used: 1, percent: 1.0}]
      assert [%{disk: nil}] = Storage.binds(nil, [], disks)
    end

    # `/mnt/tankard` is not under `/mnt/tank`, and a bare `String.starts_with?` says it is
    # -- which would report a bind as sitting on a filesystem it has nothing to do with.
    test "a sibling filesystem with a shared prefix is not matched" do
      disks = [%{mount: "/mnt/tankard", total: 100, used: 1, percent: 1.0}]
      assert [%{disk: nil}] = Storage.binds(nil, [], disks)
    end

    test "a sibling root with a shared prefix does not claim the bind" do
      Storage.put_mount_root("tank", "/mnt/tankard")
      assert [%{root: nil}] = Storage.binds(nil, Storage.mount_roots(), [])
    end

    test "a bind under a registered root is attributed to it" do
      Storage.put_mount_root("tank", "/mnt/tank")
      assert [%{root: %{name: "tank"}}] = Storage.binds(nil, Storage.mount_roots(), [])
    end
  end

  describe "create_volume validation" do
    test "refuses a blank name" do
      assert {:error, message} = Storage.create_volume(%{"name" => "  "})
      assert message =~ "needs a name"
    end

    test "refuses a name Docker would reject" do
      assert {:error, message} = Storage.create_volume(%{"name" => "my volume!"})
      assert message =~ "letters, numbers"
    end

    test "refuses a relative backing folder" do
      assert {:error, message} =
               Storage.create_volume(%{"name" => "cache", "device" => "mnt/tank"})

      assert message =~ "absolute"
    end

    # Docker does NOT create a device-bind volume's folder; it creates the volume happily
    # and fails at mount time, which surfaces as a deploy failure with no obvious cause.
    test "refuses a backing folder that does not exist" do
      assert {:error, message} =
               Storage.create_volume(%{
                 "name" => "cache",
                 "device" => "/definitely/not/here/at/all"
               })

      assert message =~ "does not exist"
    end
  end
end
