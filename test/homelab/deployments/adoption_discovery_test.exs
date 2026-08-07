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

  # WHAT THE KERNEL LET IT DO. A tunnel container needs NET_ADMIN and /dev/net/tun to
  # bring its interface up; a Zigbee bridge needs its USB device; gluetun needs
  # `src_valid_mark` for policy routing to survive. Adoption read HostConfig for the
  # restart policy and the network mode and stopped there, so the replacement came up
  # stripped of all three — and gluetun fails closed, so an adopted VPN takes every app
  # in its namespace offline with it while the import reports success.
  #
  # ComposeParser captured all four from the compose file. Importing the same stack from
  # its RUNNING containers dropped them: the capability existed, on one producer.
  test "captures the kernel privileges the original was granted" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "HostConfig" => %{
            "RestartPolicy" => %{"Name" => "always"},
            "CapAdd" => ["NET_ADMIN"],
            "CapDrop" => ["ALL"],
            "Devices" => [
              %{
                "PathOnHost" => "/dev/net/tun",
                "PathInContainer" => "/dev/net/tun",
                "CgroupPermissions" => "rwm"
              }
            ],
            "Sysctls" => %{"net.ipv4.conf.all.src_valid_mark" => "1"}
          }
        })
      )

    assert cap.capabilities_add == ["NET_ADMIN"]
    assert cap.capabilities_drop == ["ALL"]
    assert cap.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}

    assert [%{"host_path" => "/dev/net/tun", "container_path" => "/dev/net/tun"} = dev] =
             cap.devices

    assert dev["permissions"] == "rwm"
  end

  # A container granted nothing must not come back carrying empty keys that later read
  # as "explicitly none" — nil means inherit, [] means the operator chose none.
  test "a container with no privileges captures empty, not nil-shaped garbage" do
    cap = AdoptionDiscovery.capture(inspect_json(%{}))

    assert cap.capabilities_add == []
    assert cap.capabilities_drop == []
    assert cap.devices == []
    assert cap.sysctls == %{}
  end

  # WHEN it is ready, as opposed to merely started. `Config` on a container inspect is the
  # EFFECTIVE config, so an image-level HEALTHCHECK appears here even though the compose
  # file never mentioned one — the gluetun case exactly.
  test "captures the healthcheck, converting Docker's nanoseconds to seconds" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "Config" => %{
            "Image" => "qmcgaw/gluetun:latest",
            "Healthcheck" => %{
              "Test" => ["CMD-SHELL", "/gluetun-entrypoint healthcheck"],
              "Interval" => 30_000_000_000,
              "Timeout" => 5_000_000_000,
              "Retries" => 5,
              "StartPeriod" => 20_000_000_000
            }
          }
        })
      )

    assert cap.health_check["test"] == ["CMD-SHELL", "/gluetun-entrypoint healthcheck"]
    assert cap.health_check["interval"] == 30
    assert cap.health_check["timeout"] == 5
    assert cap.health_check["retries"] == 5
    assert cap.health_check["start_period"] == 20
  end

  # `["NONE"]` is Docker's explicit "this image ships a healthcheck and I do not want it".
  # Captured verbatim it would emit a literal `NONE` command that fails every probe, so an
  # adopted container that was deliberately unchecked would come up permanently unhealthy.
  test "an explicitly disabled healthcheck adopts as none, not as a NONE command" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{"Config" => %{"Healthcheck" => %{"Test" => ["NONE"]}}})
      )

    assert cap.health_check == %{}
  end

  test "a container with no healthcheck captures none" do
    assert AdoptionDiscovery.capture(inspect_json(%{})).health_check == %{}
  end

  # HOW the container was reached, not just what it ran. A host-network original has no
  # port bindings for the cutover's port import to read, so this is the only signal that
  # it was reachable at all — and the only way the replacement keeps the broadcast /
  # multicast traffic (mDNS, SSDP) that host networking exists for.
  test "captures host networking from HostConfig.NetworkMode" do
    cap =
      AdoptionDiscovery.capture(
        inspect_json(%{
          "HostConfig" => %{"NetworkMode" => "host", "RestartPolicy" => %{"Name" => "always"}}
        })
      )

    assert cap.host_network == true
  end

  test "a container on a user-defined or default network is not host-networked" do
    for mode <- ["bridge", "homelab_tenant_friends", "container:other", nil] do
      cap =
        AdoptionDiscovery.capture(
          inspect_json(%{
            "HostConfig" => %{"NetworkMode" => mode, "RestartPolicy" => %{"Name" => "always"}}
          })
        )

      refute cap.host_network, "NetworkMode #{inspect(mode)} is not host networking"
    end
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

    # The regression: adopt a service, re-scan, and it is offered for adoption AGAIN.
    # An adopted container keeps the original's name and mounts the original's bind under
    # the adoption root, so it passes every scope check. Only the label we stamped on it
    # says otherwise — and discovery did not read labels at all.
    test "a container we already adopted does not come back in the import list" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/json?all=true" ->
            {:ok, [%{"Id" => "adopted"}, %{"Id" => "fresh"}]}

          # Post-cutover: same name, same bind, but it is OURS now.
          "/containers/adopted/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "adopted",
               "Name" => "/homelab-postgres",
               "Config" => %{
                 "Image" => "postgres:16.2",
                 "User" => "",
                 "Labels" => %{
                   "homelab.managed" => "true",
                   "homelab.adopted" => "true"
                 }
               },
               "Mounts" => [
                 %{
                   "Type" => "bind",
                   "Source" => "/srv/homelab/appdata/pg",
                   "Destination" => "/var/lib/postgresql/data",
                   "RW" => true
                 }
               ]
             })}

          # An unadopted neighbour, still on the old stack.
          "/containers/fresh/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "fresh",
               "Name" => "/homelab-sonarr",
               "Mounts" => [
                 %{
                   "Type" => "bind",
                   "Source" => "/srv/homelab/appdata/sonarr",
                   "Destination" => "/config",
                   "RW" => true
                 }
               ]
             })}
        end
      end)

      assert {:ok, [cap]} = AdoptionDiscovery.discover_in_scope()
      assert cap.name == "homelab-sonarr"
    end

    # A compose stack's data services routinely have NO bind at all — Sail's redis, minio
    # and meilisearch keep everything in named volumes. Adopting only the containers that
    # happen to hold a bind half-adopts the stack: the adopted half moves onto the plane's
    # network, the rest stays behind, and the app loses every sibling it reaches by name.
    test "a compose sibling with no bind of its own is pulled into scope by its project" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/json?all=true" ->
            {:ok, [%{"Id" => "app"}, %{"Id" => "redis"}, %{"Id" => "stranger"}]}

          # The anchor: a bind under the adoption root.
          "/containers/app/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "app",
               "Name" => "/marketplace-laravel.test-1",
               "Config" => %{
                 "Image" => "marketplace/app",
                 "User" => "",
                 "Labels" => %{
                   "com.docker.compose.project" => "marketplace",
                   "com.docker.compose.service" => "laravel.test"
                 }
               },
               "Mounts" => [
                 %{
                   "Type" => "bind",
                   "Source" => "/srv/homelab/marketplace",
                   "Destination" => "/var/www/html",
                   "RW" => true
                 }
               ]
             })}

          # Same project, no bind — invisible on its own, and holding the real data.
          "/containers/redis/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "redis",
               "Name" => "/marketplace-redis-1",
               "Config" => %{
                 "Image" => "redis:7",
                 "User" => "",
                 "Labels" => %{
                   "com.docker.compose.project" => "marketplace",
                   "com.docker.compose.service" => "redis"
                 }
               },
               "Mounts" => [
                 %{
                   "Type" => "volume",
                   "Name" => "marketplace_sail-redis",
                   "Source" => "/var/lib/docker/volumes/marketplace_sail-redis/_data",
                   "Destination" => "/data",
                   "RW" => true
                 }
               ]
             })}

          # A DIFFERENT project, also bind-less. Must NOT be dragged in.
          "/containers/stranger/json" ->
            {:ok,
             inspect_json(%{
               "Id" => "stranger",
               "Name" => "/other-redis-1",
               "Config" => %{
                 "Image" => "redis:7",
                 "User" => "",
                 "Labels" => %{"com.docker.compose.project" => "other"}
               },
               "Mounts" => []
             })}
        end
      end)

      assert {:ok, captures} = AdoptionDiscovery.discover_in_scope()
      names = Enum.map(captures, & &1.name) |> Enum.sort()

      assert names == ["marketplace-laravel.test-1", "marketplace-redis-1"]

      # And the promoted sibling's data is re-tiered — it cannot derive its own verdict
      # from its own (bind-less) mounts, so it is handed the answer.
      redis = Enum.find(captures, &(&1.name == "marketplace-redis-1"))
      assert [%{tier: :preserve, source: "marketplace_sail-redis"}] = redis.mounts
    end

    test "capture carries the names the rest of the stack reaches it by" do
      body =
        inspect_json(%{
          "Name" => "/marketplace-mysql-1",
          "Config" => %{
            "Image" => "mysql:8.4",
            "User" => "",
            "Labels" => %{
              "com.docker.compose.project" => "marketplace",
              "com.docker.compose.service" => "mysql"
            }
          },
          "NetworkSettings" => %{
            "Networks" => %{"marketplace_sail" => %{"Aliases" => ["mysql", "abc123def456"]}}
          }
        })

      cap = AdoptionDiscovery.capture(body)

      assert cap.compose_project == "marketplace"
      assert cap.compose_service == "mysql"

      # The app's config says DB_HOST=mysql, not DB_HOST=marketplace-mysql-1. Both must
      # survive the rename.
      assert "mysql" in cap.aliases
      assert "marketplace-mysql-1" in cap.aliases
    end

    # Not capturing the command is not a loud failure, which is what makes it dangerous.
    # minio's overridden `command` exits immediately and is caught by verify_integrity.
    # redis's `--requirepass` override does NOT: the image default comes up perfectly
    # happily, as an UNAUTHENTICATED redis, and the adoption reports success.
    test "capture records what the container actually runs" do
      cap =
        AdoptionDiscovery.capture(
          inspect_json(%{
            "Name" => "/marketplace-redis-1",
            "Config" => %{
              "Image" => "redis:7.4-alpine",
              "User" => "",
              "Cmd" => ["redis-server", "--requirepass", "password", "--protected-mode", "yes"],
              "Entrypoint" => ["docker-entrypoint.sh"]
            }
          })
        )

      assert cap.command == [
               "redis-server",
               "--requirepass",
               "password",
               "--protected-mode",
               "yes"
             ]

      assert cap.entrypoint == ["docker-entrypoint.sh"]
    end

    test "no command means the image default, not an empty command" do
      cap = AdoptionDiscovery.capture(inspect_json(%{"Config" => %{"Image" => "x", "Cmd" => []}}))

      assert cap.command == nil
      assert cap.entrypoint == nil
    end

    test "capture records whether a container is already ours" do
      body =
        inspect_json(%{
          "Config" => %{
            "Image" => "postgres:16.2",
            "User" => "",
            "Labels" => %{"homelab.managed" => "true"}
          }
        })

      assert AdoptionDiscovery.capture(body).managed
      refute AdoptionDiscovery.capture(inspect_json(%{})).managed
    end
  end
end
