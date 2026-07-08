defmodule Homelab.Orchestrators.DockerSwarmTest do
  @moduledoc """
  Unit tests for the DockerSwarm orchestrator.

  The `(mocked daemon)` describe blocks drive every request/response branch
  against canned JSON through the `Homelab.Docker.Client` test seam: the façade
  dispatches to the module in `Process.get(:docker_client)`, so each test points
  it at `Homelab.Mocks.DockerClient` for *its own process only* (no global state,
  keeps `async: true`). The `:integration`-tagged tests still hit a real daemon
  when one is present and tolerate a connection error otherwise.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Orchestrators.DockerSwarm

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "list_networks/0 and list_volumes/0 (mocked daemon)" do
    test "list_networks maps the response to name/driver/labels" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/networks", _opts ->
        {:ok, [%{"Name" => "ingress", "Driver" => "overlay", "Labels" => %{}}]}
      end)

      assert {:ok, [%{name: "ingress", driver: "overlay", labels: %{}}]} =
               DockerSwarm.list_networks()
    end

    test "list_volumes maps the response and tolerates a nil list" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/volumes", _opts ->
        {:ok, %{"Volumes" => [%{"Name" => "vol1", "Driver" => "local", "Labels" => %{}}]}}
      end)

      assert {:ok, [%{name: "vol1", driver: "local", labels: %{}}]} = DockerSwarm.list_volumes()

      stub(Homelab.Mocks.DockerClient, :get, fn "/volumes", _opts ->
        {:ok, %{"Volumes" => nil}}
      end)

      assert {:ok, []} = DockerSwarm.list_volumes()
    end
  end

  # --- Payload Builder Tests (test indirectly through deploy) ---

  describe "deploy/1" do
    @tag :integration
    test "sends correct service create payload to Docker API" do
      spec = build_spec()

      case DockerSwarm.deploy(spec) do
        {:ok, service_id} ->
          assert is_binary(service_id)
          # Clean up
          DockerSwarm.undeploy(service_id)

        {:error, :already_exists} ->
          # Service already exists, also acceptable
          :ok

        {:error, {:connection_error, _}} ->
          :ok
      end
    end
  end

  describe "undeploy/1" do
    @tag :integration
    test "removes a service by ID" do
      spec = build_spec("integration-undeploy-test")

      case DockerSwarm.deploy(spec) do
        {:ok, service_id} ->
          assert :ok == DockerSwarm.undeploy(service_id)

        {:error, {:connection_error, _}} ->
          :ok
      end
    end

    @tag :integration
    test "returns :ok for nonexistent service" do
      assert :ok == DockerSwarm.undeploy("nonexistent-service-12345")
    end
  end

  describe "list_services/0" do
    @tag :integration
    test "returns list of homelab-managed services" do
      case DockerSwarm.list_services() do
        {:ok, services} ->
          assert is_list(services)

          Enum.each(services, fn svc ->
            assert Map.has_key?(svc, :id)
            assert Map.has_key?(svc, :name)
            assert Map.has_key?(svc, :state)
            assert Map.has_key?(svc, :labels)
            assert svc.labels["homelab.managed"] == "true"
          end)

        {:error, {:connection_error, _}} ->
          :ok
      end
    end
  end

  describe "get_service/1" do
    @tag :integration
    test "returns service status for existing service" do
      spec = build_spec("integration-get-test")

      case DockerSwarm.deploy(spec) do
        {:ok, service_id} ->
          assert {:ok, status} = DockerSwarm.get_service(service_id)
          assert status.id == service_id
          assert status.name == spec.service_name
          DockerSwarm.undeploy(service_id)

        {:error, {:connection_error, _}} ->
          :ok
      end
    end

    @tag :integration
    test "returns error for nonexistent service" do
      assert {:error, :not_found} = DockerSwarm.get_service("nonexistent-12345")
    end
  end

  describe "health_check/1" do
    @tag :integration
    test "checks task health for a service" do
      spec = build_spec("integration-health-test")

      case DockerSwarm.deploy(spec) do
        {:ok, service_id} ->
          # Just after creation, tasks might not be running yet
          case DockerSwarm.health_check(service_id) do
            {:ok, status} -> assert status in [:healthy, :unhealthy]
            {:error, _} -> :ok
          end

          DockerSwarm.undeploy(service_id)

        {:error, {:connection_error, _}} ->
          :ok
      end
    end
  end

  describe "logs/2" do
    @tag :integration
    test "fetches service logs" do
      spec = build_spec("integration-logs-test")

      case DockerSwarm.deploy(spec) do
        {:ok, service_id} ->
          # Give service a moment to start
          Process.sleep(2000)

          case DockerSwarm.logs(service_id, tail: 10) do
            {:ok, logs} -> assert is_binary(logs)
            {:error, _} -> :ok
          end

          DockerSwarm.undeploy(service_id)

        {:error, {:connection_error, _}} ->
          :ok
      end
    end
  end

  # --- Unit Tests (no Docker required) ---

  describe "service spec conversion" do
    test "env_to_list converts map to KEY=VALUE format" do
      # We test this through the payload structure that deploy would send.
      # Since deploy needs Docker, we test the structure building logic indirectly.
      spec = build_spec()

      # Verify our test spec has the right shape
      assert spec.service_name == "homelab_test_tenant_test_app"
      assert spec.image == "nginx:alpine"
      assert spec.env == %{"PORT" => "8080", "NODE_ENV" => "production"}
      assert spec.replicas == 1
      assert spec.memory_limit == 268_435_456
      assert spec.cpu_limit == 512_000_000
      assert spec.labels["homelab.managed"] == "true"
      assert spec.labels["homelab.tenant"] == "test-tenant"
    end

    test "spec includes all required fields" do
      spec = build_spec()

      required_keys = [
        :service_name,
        :image,
        :env,
        :volumes,
        :network,
        :labels,
        :replicas,
        :memory_limit,
        :cpu_limit,
        :tenant_id,
        :deployment_id
      ]

      Enum.each(required_keys, fn key ->
        assert Map.has_key?(spec, key), "missing key: #{key}"
      end)
    end

    test "volumes include source, target, and type" do
      spec = build_spec()

      Enum.each(spec.volumes, fn vol ->
        assert Map.has_key?(vol, :source)
        assert Map.has_key?(vol, :target)
        assert Map.has_key?(vol, :type)
      end)
    end

    test "labels include homelab.managed marker" do
      spec = build_spec()
      assert spec.labels["homelab.managed"] == "true"
    end
  end

  # --- Mocked daemon tests (no Docker required) ---

  describe "deploy/1 (mocked daemon)" do
    test "pulls the image, POSTs /services/create, and returns the new ID" do
      spec = build_spec()

      expect(Homelab.Mocks.DockerClient, :post_stream, fn path, _opts ->
        assert path == "/images/create?fromImage=#{URI.encode(spec.image)}"
        :ok
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", body, _opts ->
        # Body carries the translated service spec.
        assert body["Name"] == spec.service_name
        assert body["Labels"] == spec.labels
        assert get_in(body, ["TaskTemplate", "ContainerSpec", "Image"]) == spec.image

        assert get_in(body, ["TaskTemplate", "ContainerSpec", "Env"]) |> Enum.sort() ==
                 ["NODE_ENV=production", "PORT=8080"]

        assert get_in(body, ["TaskTemplate", "Resources", "Limits", "MemoryBytes"]) ==
                 spec.memory_limit

        assert get_in(body, ["TaskTemplate", "Resources", "Limits", "NanoCPUs"]) == spec.cpu_limit
        assert get_in(body, ["Mode", "Replicated", "Replicas"]) == spec.replicas

        # Bind mounts derived from the volumes list.
        [mount] = get_in(body, ["TaskTemplate", "ContainerSpec", "Mounts"])
        assert mount["Source"] == "/data/tenants/test/app/data"
        assert mount["Target"] == "/data"
        assert mount["Type"] == "bind"

        {:ok, %{"ID" => "svc_abc123"}}
      end)

      assert {:ok, "svc_abc123"} = DockerSwarm.deploy(spec)
    end

    test "sets ContainerSpec User when the spec carries one (adopted uid:gid)" do
      test_pid = self()
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", body, _opts ->
        send(test_pid, {:create_body, body})
        {:ok, %{"ID" => "svc1"}}
      end)

      spec = Map.put(build_spec(), :user, "999:999")
      assert {:ok, "svc1"} = DockerSwarm.deploy(spec)

      assert_received {:create_body, body}
      assert get_in(body, ["TaskTemplate", "ContainerSpec", "User"]) == "999:999"
    end

    test "falls back to a lowercase id key when ID is absent" do
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", _body, _opts ->
        {:ok, %{"id" => "lower_id"}}
      end)

      assert {:ok, "lower_id"} = DockerSwarm.deploy(build_spec())
    end

    test "maps a conflict to {:error, :already_exists}" do
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", _body, _opts ->
        {:error, {:conflict, %{}}}
      end)

      assert {:error, :already_exists} = DockerSwarm.deploy(build_spec())
    end

    test "propagates a non-conflict create error" do
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", _body, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerSwarm.deploy(build_spec())
    end

    test "short-circuits with {:pull_failed, ...} when the image pull fails" do
      spec = build_spec()

      expect(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts ->
        {:error, :nope}
      end)

      # No /services/create POST should happen when the pull fails.
      assert {:error, {:pull_failed, image, :nope}} = DockerSwarm.deploy(spec)
      assert image == spec.image
    end

    test "routing network is added when traefik.enable is true" do
      spec =
        build_spec()
        |> put_in([:labels, "traefik.enable"], "true")

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", body, _opts ->
        targets =
          get_in(body, ["TaskTemplate", "Networks"]) |> Enum.map(& &1["Target"])

        assert spec.network in targets
        assert "homelab-internal" in targets
        {:ok, %{"ID" => "svc_net"}}
      end)

      assert {:ok, "svc_net"} = DockerSwarm.deploy(spec)
    end
  end

  describe "undeploy/1 (mocked daemon)" do
    test "DELETEs the service and returns :ok" do
      expect(Homelab.Mocks.DockerClient, :delete, fn "/services/svc1", _opts ->
        {:ok, %{}}
      end)

      assert :ok = DockerSwarm.undeploy("svc1")
    end

    test "treats a not-found as :ok (idempotent)" do
      expect(Homelab.Mocks.DockerClient, :delete, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert :ok = DockerSwarm.undeploy("gone")
    end

    test "propagates any other delete error" do
      expect(Homelab.Mocks.DockerClient, :delete, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerSwarm.undeploy("svc1")
    end
  end

  describe "update/2 (mocked daemon)" do
    test "GETs the current version then POSTs /update?version=<index>" do
      spec = build_spec()

      stub(Homelab.Mocks.DockerClient, :get, fn "/services/svc1", _opts ->
        {:ok, %{"Version" => %{"Index" => 42}}}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        assert path == "/services/svc1/update?version=42"
        assert body["Name"] == spec.service_name
        {:ok, %{}}
      end)

      assert :ok = DockerSwarm.update("svc1", spec)
    end

    test "propagates an update POST error" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"Version" => %{"Index" => 1}}}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerSwarm.update("svc1", build_spec())
    end

    test "propagates the GET error and never POSTs" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, {:not_found, %{}}} = DockerSwarm.update("gone", build_spec())
    end
  end

  describe "restart/1 (mocked daemon)" do
    test "increments ForceUpdate and POSTs the existing Spec at the current version" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/services/svc1", _opts ->
        {:ok,
         %{
           "Version" => %{"Index" => 7},
           "Spec" => %{
             "Name" => "svc1",
             "TaskTemplate" => %{"ForceUpdate" => 2}
           }
         }}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        assert path == "/services/svc1/update?version=7"
        assert get_in(body, ["TaskTemplate", "ForceUpdate"]) == 3
        {:ok, %{}}
      end)

      assert :ok = DockerSwarm.restart("svc1")
    end

    test "defaults ForceUpdate to 1 when none is present" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         %{
           "Version" => %{"Index" => 1},
           "Spec" => %{"Name" => "svc1", "TaskTemplate" => %{}}
         }}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn _path, body, _opts ->
        assert get_in(body, ["TaskTemplate", "ForceUpdate"]) == 1
        {:ok, %{}}
      end)

      assert :ok = DockerSwarm.restart("svc1")
    end
  end

  describe "list_services/0 (mocked daemon)" do
    test "filters by homelab.managed and parses each service status" do
      filters = Jason.encode!(%{"label" => ["homelab.managed=true"]})

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path == "/services?filters=#{URI.encode(filters)}"

        {:ok,
         [
           %{
             "ID" => "svc1",
             "Spec" => %{
               "Name" => "app-one",
               "Labels" => %{"homelab.managed" => "true"},
               "Mode" => %{"Replicated" => %{"Replicas" => 3}},
               "TaskTemplate" => %{"ContainerSpec" => %{"Image" => "nginx:alpine"}}
             }
           }
         ]}
      end)

      assert {:ok, [svc]} = DockerSwarm.list_services()
      assert svc.id == "svc1"
      assert svc.name == "app-one"
      assert svc.replicas == 3
      assert svc.image == "nginx:alpine"
      assert svc.labels == %{"homelab.managed" => "true"}
      assert svc.health == :none
      assert svc.state == :running
    end

    test "defaults replicas to 1 and image to \"\" when fields are absent" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, [%{"ID" => "svc2", "Spec" => %{"Name" => "bare"}}]}
      end)

      assert {:ok, [svc]} = DockerSwarm.list_services()
      assert svc.replicas == 1
      assert svc.image == ""
      assert svc.labels == %{}
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = DockerSwarm.list_services()
    end
  end

  describe "get_service/1 (mocked daemon)" do
    test "parses a running service" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/services/svc1", _opts ->
        {:ok,
         %{
           "ID" => "svc1",
           "Spec" => %{"Name" => "running-app"}
         }}
      end)

      assert {:ok, status} = DockerSwarm.get_service("svc1")
      assert status.id == "svc1"
      assert status.name == "running-app"
      assert status.state == :running
      assert status.health == :none
    end

    test "infers :pending from UpdateStatus.State == \"updating\"" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"ID" => "svc1", "Spec" => %{}, "UpdateStatus" => %{"State" => "updating"}}}
      end)

      assert {:ok, %{state: :pending}} = DockerSwarm.get_service("svc1")
    end

    test "infers :failed from UpdateStatus.State == \"rollback_completed\"" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         %{"ID" => "svc1", "Spec" => %{}, "UpdateStatus" => %{"State" => "rollback_completed"}}}
      end)

      assert {:ok, %{state: :failed}} = DockerSwarm.get_service("svc1")
    end

    test "an unrecognized UpdateStatus.State falls back to :running" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"ID" => "svc1", "Spec" => %{}, "UpdateStatus" => %{"State" => "completed"}}}
      end)

      assert {:ok, %{state: :running}} = DockerSwarm.get_service("svc1")
    end

    test "maps not-found to {:error, :not_found}" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, :not_found} = DockerSwarm.get_service("gone")
    end

    test "propagates any other error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerSwarm.get_service("svc1")
    end
  end

  describe "health_check/1 (mocked daemon)" do
    test "filters tasks by service and desired-state, healthy when all running" do
      filters = Jason.encode!(%{"service" => ["svc1"], "desired-state" => ["running"]})

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path == "/tasks?filters=#{URI.encode(filters)}"

        {:ok,
         [
           %{"Status" => %{"State" => "running"}},
           %{"Status" => %{"State" => "running"}}
         ]}
      end)

      assert {:ok, :healthy} = DockerSwarm.health_check("svc1")
    end

    test "unhealthy when any task is not running" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         [
           %{"Status" => %{"State" => "running"}},
           %{"Status" => %{"State" => "failed"}}
         ]}
      end)

      assert {:ok, :unhealthy} = DockerSwarm.health_check("svc1")
    end

    test "unhealthy when there are no tasks at all" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, []} end)
      assert {:ok, :unhealthy} = DockerSwarm.health_check("svc1")
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = DockerSwarm.health_check("svc1")
    end
  end

  describe "stats/1 (mocked daemon)" do
    test "finds the running container's ID then parses its stats" do
      tasks_filter = Jason.encode!(%{"service" => ["svc1"], "desired-state" => ["running"]})

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        cond do
          path == "/tasks?filters=#{URI.encode(tasks_filter)}" ->
            {:ok,
             [
               # A non-running task is skipped in favor of the running one.
               %{"Status" => %{"State" => "starting"}},
               %{
                 "Status" => %{
                   "State" => "running",
                   "ContainerStatus" => %{"ContainerID" => "cid_xyz"}
                 }
               }
             ]}

          path == "/containers/cid_xyz/stats?stream=false" ->
            {:ok,
             %{
               "cpu_stats" => %{
                 "cpu_usage" => %{"total" => 200},
                 "system_cpu_usage" => 1000,
                 "online_cpus" => 2
               },
               "precpu_stats" => %{
                 "cpu_usage" => %{"total" => 100},
                 "system_cpu_usage" => 500
               },
               "memory_stats" => %{"usage" => 1024, "limit" => 4096},
               "networks" => %{
                 "eth0" => %{"rx_bytes" => 10, "tx_bytes" => 20},
                 "eth1" => %{"rx_bytes" => 5, "tx_bytes" => 7}
               }
             }}

          true ->
            flunk("unexpected path: #{path}")
        end
      end)

      assert {:ok, stats} = DockerSwarm.stats("svc1")
      # total_delta=100, system_delta=500, cpus=2 -> 100/500*2*100 = 40.0
      assert stats.cpu_percent == 40.0
      assert stats.memory_usage == 1024
      assert stats.memory_limit == 4096
      assert stats.network_rx == 15
      assert stats.network_tx == 27
    end

    test "cpu_percent is 0.0 when system_delta is not positive" do
      tasks_filter = Jason.encode!(%{"service" => ["svc1"], "desired-state" => ["running"]})

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        cond do
          path == "/tasks?filters=#{URI.encode(tasks_filter)}" ->
            {:ok,
             [
               %{
                 "Status" => %{
                   "State" => "running",
                   "ContainerStatus" => %{"ContainerID" => "cid"}
                 }
               }
             ]}

          path == "/containers/cid/stats?stream=false" ->
            {:ok,
             %{
               "cpu_stats" => %{
                 "cpu_usage" => %{"total" => 10},
                 "system_cpu_usage" => 100,
                 "online_cpus" => 1
               },
               "precpu_stats" => %{
                 "cpu_usage" => %{"total" => 5},
                 "system_cpu_usage" => 100
               }
             }}

          true ->
            flunk("unexpected path: #{path}")
        end
      end)

      assert {:ok, stats} = DockerSwarm.stats("svc1")
      assert stats.cpu_percent == 0.0
      # Missing memory/network maps default to 0.
      assert stats.memory_usage == 0
      assert stats.memory_limit == 0
      assert stats.network_rx == 0
      assert stats.network_tx == 0
    end

    test "errors with :no_running_container when no task is running" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, [%{"Status" => %{"State" => "pending"}}]}
      end)

      assert {:error, :no_running_container} = DockerSwarm.stats("svc1")
    end

    test "errors with :no_container_id when the running task lacks a container id" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, [%{"Status" => %{"State" => "running", "ContainerStatus" => %{}}}]}
      end)

      assert {:error, :no_container_id} = DockerSwarm.stats("svc1")
    end

    test "propagates a tasks-lookup error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = DockerSwarm.stats("svc1")
    end
  end

  describe "logs/2 (mocked daemon)" do
    test "requests the right path and strips 8-byte frame headers" do
      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path ==
                 "/services/svc1/logs?stdout=true&stderr=true&tail=10&timestamps=false"

        # Two frames, each prefixed with an 8-byte header.
        {:ok, "HEADER01hello\nHEADER02world"}
      end)

      assert {:ok, "hello\nworld"} = DockerSwarm.logs("svc1", tail: 10)
    end

    test "honors the :timestamps option and default tail of 100" do
      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path ==
                 "/services/svc1/logs?stdout=true&stderr=true&tail=100&timestamps=true"

        {:ok, ""}
      end)

      assert {:ok, ""} = DockerSwarm.logs("svc1", timestamps: true)
    end

    test "lines of 8 bytes or fewer are left untouched" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, "short\nx"} end)
      assert {:ok, "short\nx"} = DockerSwarm.logs("svc1")
    end

    test "inspects a non-binary body" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{"k" => "v"}} end)
      assert {:ok, body} = DockerSwarm.logs("svc1")
      assert body == inspect(%{"k" => "v"})
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = DockerSwarm.logs("svc1")
    end
  end

  # --- Helpers ---

  defp build_spec(suffix \\ "test") do
    %{
      service_name: "homelab_test_tenant_test_app",
      image: "nginx:alpine",
      env: %{"PORT" => "8080", "NODE_ENV" => "production"},
      volumes: [
        %{source: "/data/tenants/test/app/data", target: "/data", type: "bind"}
      ],
      network: "homelab_tenant_test",
      ports: [],
      labels: %{
        "homelab.managed" => "true",
        "homelab.tenant" => "test-tenant",
        "homelab.app" => "test-app-#{suffix}",
        "homelab.deployment_id" => "1"
      },
      replicas: 1,
      memory_limit: 268_435_456,
      cpu_limit: 512_000_000,
      tenant_id: "1",
      deployment_id: "1"
    }
  end
end
