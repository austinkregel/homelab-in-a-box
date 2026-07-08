defmodule Homelab.Orchestrators.DockerEngineTest do
  @moduledoc """
  Drives `Homelab.Orchestrators.DockerEngine` — the plain (non-Swarm) Docker
  Engine implementation of the Orchestrator behaviour — entirely against the
  mocked Docker client.

  Every public function delegates to `Homelab.Docker.Client`, which dispatches to
  the module in `Process.get(:docker_client)`. We point that at
  `Homelab.Mocks.DockerClient` for *this process only* (no global state mutated,
  no daemon required) and assert on both the parsed return values and the exact
  requests issued. The private response parsers (`parse_container_status`,
  `parse_inspect_status`, `parse_stats`, `strip_docker_log_headers`, the
  health-string parsing, etc.) are exercised through the public boundary.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Orchestrators.DockerEngine

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  # A minimal but complete spec map. The orchestrator reads it via dot/Map.get
  # access; tests override individual keys as needed.
  defp base_spec(overrides \\ %{}) do
    Map.merge(
      %{
        service_name: "myapp",
        image: "nginx:latest",
        network: "myapp_net",
        env: %{"FOO" => "bar"},
        labels: %{"homelab.managed" => "true"},
        memory_limit: 536_870_912,
        cpu_limit: 1_000_000_000,
        volumes: [],
        ports: []
      },
      overrides
    )
  end

  describe "deploy/1 — happy path" do
    test "ensures network, pulls image, creates + starts, returns {:ok, id}" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        send(test_pid, {:get, path})
        # Network already exists.
        {:ok, %{}}
      end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn path, _opts ->
        send(test_pid, {:post_stream, path})
        :ok
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        send(test_pid, {:post, path, body})

        cond do
          String.starts_with?(path, "/containers/create") ->
            {:ok, %{"Id" => "container-abc123"}}

          String.ends_with?(path, "/start") ->
            {:ok, %{}}

          true ->
            {:ok, %{}}
        end
      end)

      assert {:ok, "container-abc123"} = DockerEngine.deploy(base_spec())

      # Network check happened for the deployment network.
      assert_received {:get, "/networks/myapp_net"}

      # Image was pulled via a streaming POST with the URI-encoded image.
      assert_received {:post_stream, "/images/create?fromImage=nginx:latest"}

      # Container created with the service name in the query string.
      assert_received {:post, "/containers/create?name=myapp", create_body}
      assert create_body["Image"] == "nginx:latest"
      assert create_body["Env"] == ["FOO=bar"]
      assert create_body["Labels"] == %{"homelab.managed" => "true"}

      host = create_body["HostConfig"]
      assert host["Memory"] == 536_870_912
      assert host["NanoCpus"] == 1_000_000_000
      assert host["NetworkMode"] == "myapp_net"
      assert host["RestartPolicy"] == %{"Name" => "on-failure", "MaximumRetryCount" => 3}
      assert host["Mounts"] == []
      assert host["PortBindings"] == %{}

      # No ports/healthcheck on the base spec.
      refute Map.has_key?(create_body, "ExposedPorts")
      refute Map.has_key?(create_body, "Healthcheck")

      # Container started by id.
      assert_received {:post, "/containers/container-abc123/start", _}
    end

    test "skips the registry pull for locally-built images" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn path, _opts ->
        send(test_pid, {:post_stream, path})
        :ok
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "built-cid"}}
          true -> {:ok, %{}}
        end
      end)

      spec = base_spec(%{image: "homelab-built/my-app:latest"})
      assert {:ok, "built-cid"} = DockerEngine.deploy(spec)

      # No image pull should have been attempted for the local-build namespace.
      refute_received {:post_stream, _}
    end

    test "sets the container User when the spec carries one (adopted uid:gid)" do
      test_pid = self()
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        if String.starts_with?(path, "/containers/create") do
          send(test_pid, {:create_body, body})
          {:ok, %{"Id" => "cid"}}
        else
          {:ok, %{}}
        end
      end)

      assert {:ok, "cid"} = DockerEngine.deploy(base_spec(%{user: "999:999"}))
      assert_received {:create_body, body}
      assert body["User"] == "999:999"
    end

    test "omits User when the spec has none" do
      test_pid = self()
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        if String.starts_with?(path, "/containers/create") do
          send(test_pid, {:create_body, body})
          {:ok, %{"Id" => "cid"}}
        else
          {:ok, %{}}
        end
      end)

      assert {:ok, "cid"} = DockerEngine.deploy(base_spec())
      assert_received {:create_body, body}
      refute Map.has_key?(body, "User")
    end

    test "builds mounts, ports, exposed ports and healthcheck into the payload" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        if String.starts_with?(path, "/containers/create") do
          send(test_pid, {:create_body, body})
          {:ok, %{"Id" => "id1"}}
        else
          {:ok, %{}}
        end
      end)

      spec =
        base_spec(%{
          volumes: [
            %{target: "/data", source: "myapp_data", type: "volume"},
            %{target: "/host", source: "/srv/app", type: "bind"}
          ],
          ports: [%{internal: 80, external: 8080}],
          health_check: %{"Test" => ["CMD", "true"]}
        })

      assert {:ok, "id1"} = DockerEngine.deploy(spec)

      assert_received {:create_body, body}

      # Volume mount gets VolumeOptions; bind mount does not.
      assert body["HostConfig"]["Mounts"] == [
               %{
                 "Target" => "/data",
                 "Source" => "myapp_data",
                 "Type" => "volume",
                 "VolumeOptions" => %{}
               },
               %{"Target" => "/host", "Source" => "/srv/app", "Type" => "bind"}
             ]

      # Ports -> exposed ports + bindings (string host port).
      assert body["ExposedPorts"] == %{"80/tcp" => %{}}
      assert body["HostConfig"]["PortBindings"] == %{"80/tcp" => [%{"HostPort" => "8080"}]}

      # Healthcheck passed through verbatim.
      assert body["Healthcheck"] == %{"Test" => ["CMD", "true"]}
    end

    test "creates the deployment network when it does not yet exist" do
      test_pid = self()

      # Network missing -> create it.
      stub(Homelab.Mocks.DockerClient, :get, fn "/networks/" <> _ = path, _opts ->
        send(test_pid, {:get, path})
        {:error, {:not_found, %{}}}
      end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        send(test_pid, {:post, path, body})

        cond do
          path == "/networks/create" -> {:ok, %{"Id" => "net1"}}
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "id1"}}
          true -> {:ok, %{}}
        end
      end)

      assert {:ok, "id1"} = DockerEngine.deploy(base_spec())

      assert_received {:post, "/networks/create", %{"Name" => "myapp_net", "Driver" => "bridge"}}
    end
  end

  describe "deploy/1 — routing & bridge networks" do
    test "connects bridge networks and the routing network when traefik enabled" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") ->
            {:ok, %{"Id" => "cid"}}

          String.ends_with?(path, "/connect") ->
            send(test_pid, {:connect, path, body})
            {:ok, %{}}

          true ->
            {:ok, %{}}
        end
      end)

      spec =
        base_spec(%{
          bridge_networks: ["shared_net"],
          labels: %{"traefik.enable" => "true"}
        })

      assert {:ok, "cid"} = DockerEngine.deploy(spec)

      assert_received {:connect, "/networks/shared_net/connect", %{"Container" => "cid"}}
      assert_received {:connect, "/networks/homelab-internal/connect", %{"Container" => "cid"}}
    end

    test "connects the routing network when service_mode is true (no traefik label)" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") ->
            {:ok, %{"Id" => "cid"}}

          String.ends_with?(path, "/connect") ->
            send(test_pid, {:connect, path, body})
            {:ok, %{}}

          true ->
            {:ok, %{}}
        end
      end)

      spec = base_spec(%{service_mode: true})

      assert {:ok, "cid"} = DockerEngine.deploy(spec)

      assert_received {:connect, "/networks/homelab-internal/connect", %{"Container" => "cid"}}
    end

    test "does NOT connect the routing network when neither traefik nor service_mode set" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") ->
            {:ok, %{"Id" => "cid"}}

          String.ends_with?(path, "/connect") ->
            flunk("should not connect to any routing network: #{path}")

          true ->
            {:ok, %{}}
        end
      end)

      assert {:ok, "cid"} = DockerEngine.deploy(base_spec())
    end
  end

  describe "deploy/1 — failure branches" do
    test "returns {:error, {:pull_failed, image, reason}} when the image pull fails" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)

      expect(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts ->
        {:error, :timeout}
      end)

      assert {:error, {:pull_failed, "nginx:latest", :timeout}} =
               DockerEngine.deploy(base_spec())
    end

    test "propagates a container create failure" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/create?name=myapp",
                                                   _body,
                                                   _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.deploy(base_spec())
    end

    test "propagates a start failure after a successful create" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "cid"}}
          String.ends_with?(path, "/start") -> {:error, {:http_error, 500, %{}}}
          true -> {:ok, %{}}
        end
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.deploy(base_spec())
    end

    test "fails when ensure_network create fails" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, {:not_found, %{}}} end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/networks/create", _body, _opts ->
        {:error, :boom}
      end)

      assert {:error, {:network_create_failed, :boom}} = DockerEngine.deploy(base_spec())
    end
  end

  describe "deploy/1 — name conflict recovery" do
    test "on a 409 conflict, stops + force-removes the old container, then recreates" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        send(test_pid, {:delete, path})
        {:ok, %{}}
      end)

      # First create -> conflict; second create -> success.
      {:ok, agent} = Agent.start_link(fn -> 0 end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        send(test_pid, {:post, path})

        cond do
          String.starts_with?(path, "/containers/create") ->
            n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
            if n == 0, do: {:error, {:conflict, %{}}}, else: {:ok, %{"Id" => "new-cid"}}

          String.ends_with?(path, "/start") ->
            {:ok, %{}}

          true ->
            {:ok, %{}}
        end
      end)

      assert {:ok, "new-cid"} = DockerEngine.deploy(base_spec())

      # Old container stopped by name, then force-removed by name.
      assert_received {:post, "/containers/myapp/stop"}
      assert_received {:delete, "/containers/myapp?force=true"}
      assert_received {:post, "/containers/new-cid/start"}
    end

    test "returns the error when the recreate after a conflict also fails" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
      stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

      {:ok, agent} = Agent.start_link(fn -> 0 end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") ->
            n = Agent.get_and_update(agent, fn n -> {n, n + 1} end)
            if n == 0, do: {:error, {:conflict, %{}}}, else: {:error, :still_broken}

          true ->
            {:ok, %{}}
        end
      end)

      assert {:error, :still_broken} = DockerEngine.deploy(base_spec())
    end
  end

  describe "undeploy/1" do
    test "stops, force-removes, prunes empty *_net deployment networks, returns :ok" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/svc1/json" ->
            {:ok, %{"NetworkSettings" => %{"Networks" => %{"myapp_net" => %{}, "bridge" => %{}}}}}

          "/networks/myapp_net" ->
            # Empty deployment network -> eligible for pruning.
            {:ok, %{"Containers" => %{}}}

          _ ->
            {:ok, %{}}
        end
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        send(test_pid, {:post, path})
        {:ok, %{}}
      end)

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        send(test_pid, {:delete, path})
        {:ok, %{}}
      end)

      assert :ok = DockerEngine.undeploy("svc1")

      assert_received {:post, "/containers/svc1/stop"}
      assert_received {:delete, "/containers/svc1?force=true"}
      # Only the *_net network is pruned (bridge is filtered out).
      assert_received {:delete, "/networks/myapp_net"}
      refute_received {:delete, "/networks/bridge"}
    end

    test "treats a not_found on remove as :ok" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert :ok = DockerEngine.undeploy("gone")
    end

    test "does not prune a non-empty deployment network" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/containers/svc1/json" ->
            {:ok, %{"NetworkSettings" => %{"Networks" => %{"busy_net" => %{}}}}}

          "/networks/busy_net" ->
            {:ok, %{"Containers" => %{"other" => %{}}}}

          _ ->
            {:ok, %{}}
        end
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        refute path == "/networks/busy_net", "must not prune a non-empty network"
        {:ok, %{}}
      end)

      assert :ok = DockerEngine.undeploy("svc1")
    end

    test "propagates a remove error (other than not_found) and skips pruning" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)
      stub(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        # Only the container delete should be attempted; no network prune.
        assert path == "/containers/svc1?force=true"
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.undeploy("svc1")
    end
  end

  describe "restart/1" do
    test "POSTs /restart and returns :ok" do
      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/svc1/restart", _body, _opts ->
        {:ok, %{}}
      end)

      assert :ok = DockerEngine.restart("svc1")
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/svc1/restart", _body, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, {:not_found, %{}}} = DockerEngine.restart("svc1")
    end
  end

  describe "list_services/0 — parse_container_status + parse_health_string" do
    test "maps container states and parses health from the Status string" do
      containers = [
        %{
          "Id" => "id-run",
          "Names" => ["/web"],
          "State" => "running",
          "Status" => "Up 2 minutes (healthy)",
          "Image" => "nginx",
          "Labels" => %{"homelab.managed" => "true"}
        },
        %{
          "Id" => "id-unhealthy",
          "Names" => ["/api"],
          "State" => "running",
          "Status" => "Up 5 minutes (unhealthy)",
          "Image" => "api",
          "Labels" => %{}
        },
        %{
          "Id" => "id-starting",
          "Names" => ["/cache"],
          "State" => "running",
          "Status" => "Up 1 second (health: starting)",
          "Image" => "redis",
          "Labels" => %{}
        },
        %{
          "Id" => "id-exit",
          "Names" => ["/worker"],
          "State" => "exited",
          "Status" => "Exited (0) 3 minutes ago",
          "Image" => "worker"
        },
        %{
          "Id" => "id-dead",
          "Names" => ["/zombie"],
          "State" => "dead",
          "Status" => "Dead"
        },
        %{
          "Id" => "id-created",
          "Names" => ["/new"],
          "State" => "created",
          "Status" => "Created"
        }
      ]

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert String.starts_with?(path, "/containers/json?all=true&filters=")
        # Filters carry the homelab.managed=true label, URI-encoded.
        assert String.contains?(path, URI.encode("homelab.managed=true"))
        {:ok, containers}
      end)

      assert {:ok, services} = DockerEngine.list_services()
      by_id = Map.new(services, &{&1.id, &1})

      assert by_id["id-run"].state == :running
      assert by_id["id-run"].health == :healthy
      assert by_id["id-run"].name == "web"
      assert by_id["id-run"].replicas == 1
      assert by_id["id-run"].image == "nginx"
      assert by_id["id-run"].labels == %{"homelab.managed" => "true"}

      assert by_id["id-unhealthy"].health == :unhealthy
      assert by_id["id-starting"].health == :starting

      assert by_id["id-exit"].state == :stopped
      assert by_id["id-exit"].health == :none
      assert by_id["id-exit"].replicas == 0

      assert by_id["id-dead"].state == :failed
      assert by_id["id-created"].state == :pending
      # No Status string at all -> :none.
      assert by_id["id-dead"].health == :none
    end

    test "tolerates missing Names/Image/Labels with safe defaults" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, [%{"Id" => "bare", "State" => "running"}]}
      end)

      assert {:ok, [svc]} = DockerEngine.list_services()
      assert svc.name == ""
      assert svc.image == ""
      assert svc.labels == %{}
      assert svc.health == :none
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.list_services()
    end
  end

  describe "get_service/1 — parse_inspect_status + map_inspect_state" do
    test "maps Running=true to :running with structured health" do
      body = %{
        "Id" => "cid",
        "Name" => "/web",
        "Config" => %{"Image" => "nginx", "Labels" => %{"a" => "b"}},
        "State" => %{"Running" => true, "Health" => %{"Status" => "healthy"}}
      }

      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/cid/json", _opts ->
        {:ok, body}
      end)

      assert {:ok, svc} = DockerEngine.get_service("cid")
      assert svc.id == "cid"
      assert svc.name == "web"
      assert svc.state == :running
      assert svc.health == :healthy
      assert svc.replicas == 1
      assert svc.image == "nginx"
      assert svc.labels == %{"a" => "b"}
    end

    test "maps Dead=true to :failed" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"State" => %{"Dead" => true}}}
      end)

      assert {:ok, %{state: :failed, replicas: 0, health: :none}} = DockerEngine.get_service("x")
    end

    test "maps Restarting=true to :pending" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"State" => %{"Restarting" => true}}}
      end)

      assert {:ok, %{state: :pending}} = DockerEngine.get_service("x")
    end

    test "maps an idle state (none of the flags true) to :stopped" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"State" => %{"Running" => false, "Health" => %{"Status" => "unhealthy"}}}}
      end)

      assert {:ok, svc} = DockerEngine.get_service("x")
      assert svc.state == :stopped
      assert svc.replicas == 0
      assert svc.health == :unhealthy
    end

    test "health defaults to :none when no Health block present" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"State" => %{"Running" => true}}}
      end)

      assert {:ok, %{health: :none}} = DockerEngine.get_service("x")
    end

    test "returns {:error, :not_found} on a 404" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, :not_found} = DockerEngine.get_service("gone")
    end

    test "propagates other client errors" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.get_service("x")
    end
  end

  describe "health_check/1" do
    test "running -> {:ok, :healthy}" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/cid/json", _opts ->
        {:ok, %{"State" => %{"Running" => true}}}
      end)

      assert {:ok, :healthy} = DockerEngine.health_check("cid")
    end

    test "not running -> {:ok, :unhealthy}" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"State" => %{"Running" => false}}}
      end)

      assert {:ok, :unhealthy} = DockerEngine.health_check("cid")
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, :boom}
      end)

      assert {:error, :boom} = DockerEngine.health_check("cid")
    end
  end

  describe "stats/1 — parse_stats + calc_cpu_percent" do
    test "computes CPU%, memory, and summed network bytes" do
      # total_delta = 200-100 = 100; system_delta = 2000-1000 = 1000; cpus = 2
      # cpu% = 100/1000 * 2 * 100 = 20.0
      data = %{
        "cpu_stats" => %{
          "cpu_usage" => %{"total" => 200},
          "system_cpu_usage" => 2000,
          "online_cpus" => 2
        },
        "precpu_stats" => %{
          "cpu_usage" => %{"total" => 100},
          "system_cpu_usage" => 1000
        },
        "memory_stats" => %{"usage" => 1024, "limit" => 4096},
        "networks" => %{
          "eth0" => %{"rx_bytes" => 100, "tx_bytes" => 10},
          "eth1" => %{"rx_bytes" => 5, "tx_bytes" => 1}
        }
      }

      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/cid/stats?stream=false", _opts ->
        {:ok, data}
      end)

      assert {:ok, stats} = DockerEngine.stats("cid")
      assert stats.cpu_percent == 20.0
      assert stats.memory_usage == 1024
      assert stats.memory_limit == 4096
      assert stats.network_rx == 105
      assert stats.network_tx == 11
    end

    test "CPU% is 0.0 when system_delta is not positive" do
      data = %{
        "cpu_stats" => %{
          "cpu_usage" => %{"total" => 200},
          "system_cpu_usage" => 1000,
          "online_cpus" => 4
        },
        "precpu_stats" => %{
          "cpu_usage" => %{"total" => 100},
          "system_cpu_usage" => 1000
        }
      }

      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, data} end)

      assert {:ok, stats} = DockerEngine.stats("cid")
      assert stats.cpu_percent == 0.0
      assert stats.memory_usage == 0
      assert stats.memory_limit == 0
      assert stats.network_rx == 0
      assert stats.network_tx == 0
    end

    test "CPU% is 0.0 when the cpu stats shape is missing entirely" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)

      assert {:ok, stats} = DockerEngine.stats("cid")
      assert stats.cpu_percent == 0.0
    end

    test "returns {:error, :not_found} on a 404" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, :not_found} = DockerEngine.stats("gone")
    end

    test "propagates other client errors" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.stats("cid")
    end
  end

  describe "logs/1 — strip_docker_log_headers" do
    test "strips the 8-byte multiplexed stream header from each line" do
      header = <<1, 0, 0, 0, 0, 0, 0, 13>>
      line1 = header <> "hello world!!"
      line2 = header <> "second line!!"
      body = line1 <> "\n" <> line2

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path ==
                 "/containers/cid/logs?stdout=true&stderr=true&tail=100&timestamps=false"

        {:ok, body}
      end)

      assert {:ok, "hello world!!\nsecond line!!"} = DockerEngine.logs("cid")
    end

    test "leaves lines of 8 bytes or fewer untouched" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, "short\n" <> <<1, 2, 3, 4, 5, 6, 7, 8>>}
      end)

      assert {:ok, stripped} = DockerEngine.logs("cid")
      assert stripped == "short\n" <> <<1, 2, 3, 4, 5, 6, 7, 8>>
    end

    test "honors :tail and :timestamps options in the query string" do
      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path ==
                 "/containers/cid/logs?stdout=true&stderr=true&tail=10&timestamps=true"

        {:ok, ""}
      end)

      assert {:ok, ""} = DockerEngine.logs("cid", tail: 10, timestamps: true)
    end

    test "inspects a non-binary body" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"unexpected" => "shape"}}
      end)

      assert {:ok, result} = DockerEngine.logs("cid")
      assert result == inspect(%{"unexpected" => "shape"})
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, :boom}
      end)

      assert {:error, :boom} = DockerEngine.logs("cid")
    end
  end

  describe "network create / delete branches (via ensure_network & undeploy)" do
    test "ensure_network treats an existing network (200) as :ok and skips create" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn "/networks/myapp_net", _opts ->
        {:ok, %{"Name" => "myapp_net"}}
      end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        if path == "/networks/create",
          do: send(test_pid, :created_network)

        cond do
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "id1"}}
          true -> {:ok, %{}}
        end
      end)

      assert {:ok, "id1"} = DockerEngine.deploy(base_spec())
      refute_received :created_network
    end

    test "ensure_network creates the network on a 404 (not_found)" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        cond do
          path == "/networks/create" ->
            send(test_pid, {:created, body})
            {:ok, %{"Id" => "net"}}

          String.starts_with?(path, "/containers/create") ->
            {:ok, %{"Id" => "id1"}}

          true ->
            {:ok, %{}}
        end
      end)

      assert {:ok, "id1"} = DockerEngine.deploy(base_spec())
      assert_received {:created, %{"Name" => "myapp_net", "Driver" => "bridge"}}
    end

    test "ensure_network propagates a non-404 GET error without creating" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn "/networks/create", _body, _opts ->
        flunk("must not attempt to create a network on a non-404 error")
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.deploy(base_spec())
    end
  end

  describe "list_networks/0" do
    test "maps the /networks response to name/driver/labels" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/networks", _opts ->
        {:ok,
         [
           %{"Name" => "bridge", "Driver" => "bridge", "Labels" => %{}},
           %{"Name" => "homelab-internal", "Driver" => "bridge", "Labels" => %{"a" => "b"}}
         ]}
      end)

      assert {:ok, networks} = DockerEngine.list_networks()

      assert networks == [
               %{name: "bridge", driver: "bridge", labels: %{}},
               %{name: "homelab-internal", driver: "bridge", labels: %{"a" => "b"}}
             ]
    end

    test "propagates an error" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/networks", _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerEngine.list_networks()
    end
  end

  describe "list_volumes/0" do
    test "maps the /volumes response to name/driver/labels" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/volumes", _opts ->
        {:ok,
         %{
           "Volumes" => [
             %{"Name" => "data", "Driver" => "local", "Labels" => %{"k" => "v"}}
           ],
           "Warnings" => nil
         }}
      end)

      assert {:ok, [%{name: "data", driver: "local", labels: %{"k" => "v"}}]} =
               DockerEngine.list_volumes()
    end

    test "returns [] when the daemon reports no volumes" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/volumes", _opts ->
        {:ok, %{"Volumes" => nil}}
      end)

      assert {:ok, []} = DockerEngine.list_volumes()
    end
  end

  describe "behaviour contract" do
    test "declares the Orchestrator behaviour" do
      behaviours = DockerEngine.module_info(:attributes)[:behaviour] || []
      assert Homelab.Behaviours.Orchestrator in behaviours
    end

    test "static identity functions" do
      assert DockerEngine.driver_id() == "docker_engine"
      assert DockerEngine.display_name() == "Docker Engine"
      assert is_binary(DockerEngine.description())
    end
  end
end
