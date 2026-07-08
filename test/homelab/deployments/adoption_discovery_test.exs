defmodule Homelab.Deployments.AdoptionDiscoveryTest do
  # async: false — pins the global :adoption_root so scope checks are deterministic.
  use ExUnit.Case, async: false

  import Mox

  alias Homelab.Deployments.AdoptionDiscovery

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
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

  # Real-shaped `GET /containers/{id}/json` fragments (captured from the daemon).
  defp inspect_json(overrides) do
    Map.merge(
      %{
        "Id" => "abc123",
        "Name" => "/homelab-postgres",
        "Config" => %{"Image" => "postgres:16.2", "User" => ""},
        "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}},
        "State" => %{"Status" => "running"},
        "Mounts" => []
      },
      overrides
    )
  end

  test "captures identity, user, restart policy, and strips the leading slash from the name" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Name" => "/matrix-postgres",
          "Config" => %{"Image" => "postgres:16.2", "User" => "999:999"},
          "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}
        })
      )

    assert cap.name == "matrix-postgres"
    assert cap.image == "postgres:16.2"
    assert cap.user == "999:999"
    assert cap.restart_policy == "always"
    assert cap.state == "running"
  end

  test "blank Config.User becomes nil" do
    assert AdoptionDiscovery.capture(inspect_json(%{})).user == nil
  end

  test "a bind mount under root is captured and preserved" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Mounts" => [
            %{
              "Type" => "bind",
              "Source" => "/srv/homelab/appdata/homelab-postgres",
              "Destination" => "/var/lib/postgresql/data",
              "RW" => true
            }
          ]
        })
      )

    assert cap.in_scope
    assert [mount] = cap.mounts
    assert mount.type == "bind"
    assert mount.source == "/srv/homelab/appdata/homelab-postgres"
    assert mount.target == "/var/lib/postgresql/data"
    assert mount.anonymous == false
    assert mount.tier == :preserve
  end

  test "a named volume's source is the volume NAME, with mountpoint kept separately" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Name" => "/homelab-mariadb",
          "Mounts" => [
            %{
              "Type" => "bind",
              "Source" => "/srv/homelab/scripts/create-mariadb-database.sh",
              "Destination" => "/docker-entrypoint-initdb.d/x.sh",
              "RW" => true
            },
            %{
              "Type" => "volume",
              "Name" => "homelab_homelab-mariadb",
              "Source" => "/var/lib/docker/volumes/homelab_homelab-mariadb/_data",
              "Destination" => "/var/lib/mysql",
              "RW" => true
            }
          ]
        })
      )

    assert cap.in_scope
    vol = Enum.find(cap.mounts, &(&1.type == "volume"))
    assert vol.source == "homelab_homelab-mariadb"
    assert vol.mountpoint == "/var/lib/docker/volumes/homelab_homelab-mariadb/_data"
    assert vol.tier == :preserve
  end

  test "an anonymous volume (64-hex name) is flagged and pinned verbatim" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Name" => "/influxdb",
          "Mounts" => [
            %{
              "Type" => "bind",
              "Source" => "/srv/homelab/appdata/influxdb/config",
              "Destination" => "/etc/influxdb",
              "RW" => true
            },
            %{
              "Type" => "volume",
              "Name" => "b375626d076322a29d23154e269d96b2d20d665dfded8e99948970603934baf4",
              "Source" => "/var/lib/docker/volumes/b375626d.../_data",
              "Destination" => "/var/lib/influxdb2",
              "RW" => true
            }
          ]
        })
      )

    anon = Enum.find(cap.mounts, & &1.anonymous)
    assert anon.source == "b375626d076322a29d23154e269d96b2d20d665dfded8e99948970603934baf4"
    # influxdb is wholly rebuildable, so even the anon data volume needs no gate.
    assert anon.tier == :rebuildable
  end

  test "an out-of-scope dev container captures but marks everything out_of_scope" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Name" => "/marketplace-mysql-1",
          "State" => %{"Status" => "exited"},
          "Mounts" => [
            %{
              "Type" => "volume",
              "Name" => "marketplace_sail-mysql",
              "Source" => "/var/lib/docker/volumes/marketplace_sail-mysql/_data",
              "Destination" => "/var/lib/mysql",
              "RW" => true
            }
          ]
        })
      )

    refute cap.in_scope
    assert cap.state == "exited"
    assert Enum.all?(cap.mounts, &(&1.tier == :out_of_scope))
  end

  describe "inspect_container/1 (mocked daemon)" do
    test "GETs /containers/{id}/json and normalizes a volume mount end-to-end" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/homelab-mariadb/json", _opts ->
        {:ok,
         inspect_json(%{
           "Id" => "vol-id",
           "Name" => "/homelab-mariadb",
           "Config" => %{"Image" => "mariadb:11", "User" => "999:999"},
           "HostConfig" => %{"RestartPolicy" => %{"Name" => "unless-stopped"}},
           "Mounts" => [
             %{
               "Type" => "bind",
               "Source" => "/srv/homelab/scripts/init.sh",
               "Destination" => "/docker-entrypoint-initdb.d/x.sh",
               "RW" => true
             },
             %{
               "Type" => "volume",
               "Name" => "homelab_homelab-mariadb",
               "Source" => "/var/lib/docker/volumes/homelab_homelab-mariadb/_data",
               "Destination" => "/var/lib/mysql",
               "RW" => true
             }
           ]
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("homelab-mariadb")

      assert cap.id == "vol-id"
      assert cap.name == "homelab-mariadb"
      assert cap.image == "mariadb:11"
      assert cap.user == "999:999"
      assert cap.restart_policy == "unless-stopped"
      assert cap.in_scope

      vol = Enum.find(cap.mounts, &(&1.type == "volume"))
      assert vol.source == "homelab_homelab-mariadb"
      assert vol.target == "/var/lib/mysql"
      assert vol.mountpoint == "/var/lib/docker/volumes/homelab_homelab-mariadb/_data"
      assert vol.anonymous == false
      assert vol.rw == true
      assert vol.tier == :preserve
    end

    test "normalizes a bind mount (source IS the host path)" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/homelab-postgres/json", _opts ->
        {:ok,
         inspect_json(%{
           "Name" => "/homelab-postgres",
           "Mounts" => [
             %{
               "Type" => "bind",
               "Source" => "/srv/homelab/appdata/homelab-postgres",
               "Destination" => "/var/lib/postgresql/data",
               "RW" => true
             }
           ]
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("homelab-postgres")
      assert [mount] = cap.mounts
      assert mount.type == "bind"
      assert mount.source == "/srv/homelab/appdata/homelab-postgres"
      assert mount.mountpoint == "/srv/homelab/appdata/homelab-postgres"
      assert mount.target == "/var/lib/postgresql/data"
      assert mount.anonymous == false
      assert mount.tier == :preserve
    end

    test "normalizes a tmpfs mount (non-volume, source is host path / nil)" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         inspect_json(%{
           "Name" => "/homelab-postgres",
           "Mounts" => [
             %{
               "Type" => "bind",
               "Source" => "/srv/homelab/appdata/homelab-postgres",
               "Destination" => "/var/lib/postgresql/data",
               "RW" => true
             },
             %{
               "Type" => "tmpfs",
               "Source" => "",
               "Destination" => "/run",
               "RW" => true
             }
           ]
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("homelab-postgres")
      tmpfs = Enum.find(cap.mounts, &(&1.type == "tmpfs"))
      assert tmpfs.target == "/run"
      assert tmpfs.source == ""
      assert tmpfs.anonymous == false
    end

    test "flags and pins an anonymous (64-hex) volume verbatim, with rebuildable tier" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/influxdb/json", _opts ->
        {:ok,
         inspect_json(%{
           "Name" => "/influxdb",
           "Mounts" => [
             %{
               "Type" => "bind",
               "Source" => "/srv/homelab/appdata/influxdb/config",
               "Destination" => "/etc/influxdb",
               "RW" => true
             },
             %{
               "Type" => "volume",
               "Name" => "b375626d076322a29d23154e269d96b2d20d665dfded8e99948970603934baf4",
               "Source" => "/var/lib/docker/volumes/b375626d.../_data",
               "Destination" => "/var/lib/influxdb2",
               "RW" => true
             }
           ]
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("influxdb")
      anon = Enum.find(cap.mounts, & &1.anonymous)
      assert anon.source == "b375626d076322a29d23154e269d96b2d20d665dfded8e99948970603934baf4"
      assert anon.tier == :rebuildable
    end

    test "extracts restart policy and user; blank user becomes nil" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         inspect_json(%{
           "Config" => %{"Image" => "postgres:16.2", "User" => ""},
           "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("anything")
      assert cap.user == nil
      assert cap.restart_policy == "always"
    end

    test "an out-of-scope container marks every mount :out_of_scope" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         inspect_json(%{
           "Name" => "/marketplace-mysql-1",
           "State" => %{"Status" => "exited"},
           "Mounts" => [
             %{
               "Type" => "volume",
               "Name" => "marketplace_sail-mysql",
               "Source" => "/var/lib/docker/volumes/marketplace_sail-mysql/_data",
               "Destination" => "/var/lib/mysql",
               "RW" => true
             }
           ]
         })}
      end)

      assert {:ok, cap} = AdoptionDiscovery.inspect_container("marketplace-mysql-1")
      refute cap.in_scope
      assert Enum.all?(cap.mounts, &(&1.tier == :out_of_scope))
    end

    test "propagates a client error from the GET" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, {:not_found, %{}}} = AdoptionDiscovery.inspect_container("gone")
    end
  end

  describe "discover/0 (mocked daemon)" do
    test "lists all containers then inspects each, returning captures" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/json?all=true" ->
            {:ok, [%{"Id" => "id-a"}, %{"Id" => "id-b"}]}

          "/containers/id-a/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "id-a",
               "Name" => "/homelab-postgres",
               "Mounts" => [
                 %{
                   "Type" => "bind",
                   "Source" => "/srv/homelab/appdata/pg",
                   "Destination" => "/var/lib/postgresql/data",
                   "RW" => true
                 }
               ]
             })}

          "/containers/id-b/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "id-b",
               "Name" => "/marketplace-mysql-1",
               "Mounts" => []
             })}
        end
      end)

      assert {:ok, caps} = AdoptionDiscovery.discover()
      assert length(caps) == 2
      assert Enum.map(caps, & &1.id) == ["id-a", "id-b"]

      pg = Enum.find(caps, &(&1.name == "homelab-postgres"))
      assert pg.in_scope
      assert [%{type: "bind", tier: :preserve}] = pg.mounts
    end

    test "skips containers whose inspect errors, keeping the successful ones" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/json?all=true" ->
            {:ok, [%{"Id" => "ok"}, %{"Id" => "boom"}]}

          "/containers/ok/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "ok",
               "Name" => "/homelab-postgres",
               "Mounts" => []
             })}

          "/containers/boom/json" ->
            {:error, {:not_found, %{}}}
        end
      end)

      assert {:ok, caps} = AdoptionDiscovery.discover()
      assert Enum.map(caps, & &1.id) == ["ok"]
    end

    test "propagates an error from the list request" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/json?all=true", _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = AdoptionDiscovery.discover()
    end
  end

  describe "discover_in_scope/0 (mocked daemon)" do
    test "filters out out-of-scope captures" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/json?all=true" ->
            {:ok, [%{"Id" => "in"}, %{"Id" => "out"}]}

          "/containers/in/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "in",
               "Name" => "/homelab-postgres",
               "Mounts" => [
                 %{
                   "Type" => "bind",
                   "Source" => "/srv/homelab/appdata/pg",
                   "Destination" => "/var/lib/postgresql/data",
                   "RW" => true
                 }
               ]
             })}

          "/containers/out/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "out",
               "Name" => "/marketplace-mysql-1",
               "Mounts" => []
             })}
        end
      end)

      assert {:ok, [cap]} = AdoptionDiscovery.discover_in_scope()
      assert cap.name == "homelab-postgres"
    end
  end
end
