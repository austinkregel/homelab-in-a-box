defmodule Homelab.Deployments.AdoptionDiscoveryTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.AdoptionDiscovery

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
              "Source" => "/home/austinkregel/homelab/appdata/homelab-postgres",
              "Destination" => "/var/lib/postgresql/data",
              "RW" => true
            }
          ]
        })
      )

    assert cap.in_scope
    assert [mount] = cap.mounts
    assert mount.type == "bind"
    assert mount.source == "/home/austinkregel/homelab/appdata/homelab-postgres"
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
              "Source" => "/home/austinkregel/homelab/scripts/create-mariadb-database.sh",
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
              "Source" => "/home/austinkregel/homelab/appdata/influxdb/config",
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
end
