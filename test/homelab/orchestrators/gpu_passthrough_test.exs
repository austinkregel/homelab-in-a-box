defmodule Homelab.Orchestrators.NetworkAliasTest do
  @moduledoc """
  Adopting a container RENAMES it. Its siblings do not know that — an app's config says
  `DB_HOST=mysql`, not `DB_HOST=marketplace-mysql-1`. Without aliases, adopting a stack
  severs its own DNS.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Orchestrators.{DockerEngine, DockerSwarm}

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  defp spec(aliases) do
    %{
      service_name: "homelab_dev_adopted-marketplace-mysql-1",
      image: "mysql:8.4",
      user: nil,
      env: %{},
      volumes: [],
      ports: [],
      network: "homelab_tenant_dev",
      bridge_networks: [],
      network_aliases: aliases,
      labels: %{"homelab.managed" => "true"},
      replicas: 1,
      memory_limit: 536_870_912,
      cpu_limit: 512_000_000,
      gpu: nil,
      tenant_id: "1",
      deployment_id: "1",
      service_mode: false,
      health_check: nil
    }
  end

  defp capture_create(create_path) do
    test = self()

    stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
    stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

    stub(Homelab.Mocks.DockerClient, :get, fn
      "/nodes", _opts -> {:ok, []}
      "/networks/" <> _rest, _opts -> {:error, {:not_found, "nope"}}
      _path, _opts -> {:ok, %{}}
    end)

    stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
      if path == create_path do
        send(test, {:payload, body})
        {:ok, %{"ID" => "svc123", "Id" => "svc123"}}
      else
        {:ok, %{}}
      end
    end)

    :ok
  end

  test "DockerEngine gives the container the names its siblings call it by" do
    capture_create("/containers/create?name=homelab_dev_adopted-marketplace-mysql-1")

    DockerEngine.deploy(spec(["mysql", "marketplace-mysql-1"]))

    assert_received {:payload, payload}

    assert %{"Aliases" => ["mysql", "marketplace-mysql-1"]} =
             payload["NetworkingConfig"]["EndpointsConfig"]["homelab_tenant_dev"]
  end

  test "DockerEngine omits NetworkingConfig entirely when there are no aliases" do
    capture_create("/containers/create?name=homelab_dev_adopted-marketplace-mysql-1")

    DockerEngine.deploy(spec([]))

    assert_received {:payload, payload}
    refute Map.has_key?(payload, "NetworkingConfig")
  end

  test "DockerSwarm puts the aliases on the primary network only" do
    capture_create("/services/create")

    DockerSwarm.deploy(spec(["mysql", "marketplace-mysql-1"]))

    assert_received {:payload, payload}
    networks = payload["TaskTemplate"]["Networks"]

    primary = Enum.find(networks, &(&1["Target"] == "homelab_tenant_dev"))
    assert primary["Aliases"] == ["mysql", "marketplace-mysql-1"]

    # The shared routing network must NOT carry them: two tenants could claim the
    # same service name on it.
    for net <- networks, net["Target"] != "homelab_tenant_dev" do
      refute Map.has_key?(net, "Aliases")
    end
  end
end

defmodule Homelab.Orchestrators.GpuPassthroughTest do
  @moduledoc """
  The two drivers reach a GPU by completely different mechanisms, and only one of them
  can pass a device at all. These tests pin what each actually puts on the wire.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Deployments.GpuSpec
  alias Homelab.Orchestrators.{DockerEngine, DockerSwarm}

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  defp spec(gpu_attrs) do
    %{
      service_name: "homelab_acme_ollama",
      image: "ollama/ollama:latest",
      user: nil,
      env: %{},
      volumes: [],
      ports: [],
      network: "homelab_tenant_acme",
      bridge_networks: [],
      labels: %{"homelab.managed" => "true"},
      replicas: 1,
      memory_limit: 536_870_912,
      cpu_limit: 512_000_000,
      gpu: gpu_attrs && GpuSpec.parse(%{"gpu" => gpu_attrs}),
      tenant_id: "1",
      deployment_id: "1",
      service_mode: false,
      health_check: nil
    }
  end

  # Captures the create payload the driver sends, and short-circuits the rest of deploy.
  defp capture_create(create_path) do
    test = self()

    stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
    stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

    stub(Homelab.Mocks.DockerClient, :get, fn
      "/nodes", _opts ->
        {:ok, [gpu_node("NVIDIA-GPU")]}

      # Not found — so each driver creates the network in its own native driver rather
      # than recreating a mismatched one. The network is not what these tests are about.
      "/networks/" <> _rest, _opts ->
        {:error, {:not_found, "no such network"}}

      _path, _opts ->
        {:ok, %{}}
    end)

    stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
      if path == create_path do
        send(test, {:payload, body})
        {:ok, %{"ID" => "svc123", "Id" => "svc123"}}
      else
        {:ok, %{}}
      end
    end)

    :ok
  end

  defp gpu_node(kind) do
    %{
      "ID" => "kratos",
      "Description" => %{
        "Hostname" => "kratos",
        "Resources" => %{
          "GenericResources" => [
            %{"NamedResourceSpec" => %{"Kind" => kind, "Value" => "GPU-45cbf7b3"}}
          ]
        }
      }
    }
  end

  describe "DockerEngine — passes the device directly" do
    test "NVIDIA becomes a DeviceRequest with the gpu capability" do
      capture_create("/containers/create?name=homelab_acme_ollama")

      DockerEngine.deploy(spec(%{"vendor" => "nvidia"}))

      assert_received {:payload, payload}
      assert [request] = payload["HostConfig"]["DeviceRequests"]

      assert request["Driver"] == "nvidia"
      # -1 is the API's "every GPU on this host".
      assert request["Count"] == -1
      assert request["Capabilities"] == [["gpu"]]
    end

    test "specific NVIDIA devices become DeviceIDs, not a count" do
      capture_create("/containers/create?name=homelab_acme_ollama")

      DockerEngine.deploy(spec(%{"vendor" => "nvidia", "devices" => "0,1"}))

      assert_received {:payload, payload}
      assert [request] = payload["HostConfig"]["DeviceRequests"]

      assert request["DeviceIDs"] == ["0", "1"]
      refute Map.has_key?(request, "Count")
    end

    # ROCm needs BOTH nodes: /dev/kfd is the compute interface, /dev/dri holds the render
    # nodes. A container with only one of them fails in a way that reads like a driver bug.
    test "AMD becomes raw device nodes plus the groups that make them readable" do
      capture_create("/containers/create?name=homelab_acme_ollama")

      DockerEngine.deploy(spec(%{"vendor" => "amd"}))

      assert_received {:payload, payload}
      host_config = payload["HostConfig"]

      paths = Enum.map(host_config["Devices"], & &1["PathOnHost"])
      assert "/dev/kfd" in paths
      assert "/dev/dri" in paths

      # Without these the device nodes exist but are unreadable, and ROCm says
      # "no permission" rather than "no device".
      assert "video" in host_config["GroupAdd"]
      assert "render" in host_config["GroupAdd"]

      # AMD needs no toolkit and no device-request negotiation.
      refute Map.has_key?(host_config, "DeviceRequests")
    end

    test "no GPU means no device keys at all" do
      capture_create("/containers/create?name=homelab_acme_ollama")

      DockerEngine.deploy(spec(nil))

      assert_received {:payload, payload}
      refute Map.has_key?(payload["HostConfig"], "DeviceRequests")
      refute Map.has_key?(payload["HostConfig"], "Devices")
    end
  end

  describe "DockerSwarm — cannot pass a device, reserves a generic resource" do
    test "the GPU becomes a resource RESERVATION, which is what pins it to the GPU node" do
      capture_create("/services/create")

      DockerSwarm.deploy(spec(%{"vendor" => "nvidia"}))

      assert_received {:payload, payload}
      resources = payload["TaskTemplate"]["Resources"]

      assert [%{"DiscreteResourceSpec" => %{"Kind" => "NVIDIA-GPU", "Value" => 1}}] =
               resources["Reservations"]["GenericResources"]

      # Limits are untouched — a reservation and a limit answer different questions.
      assert resources["Limits"]["MemoryBytes"] == 536_870_912

      # Swarm rejects devices outright; sending one would fail the whole create.
      refute Map.has_key?(payload["TaskTemplate"]["ContainerSpec"], "Devices")
      refute get_in(payload, ["TaskTemplate", "ContainerSpec", "DeviceRequests"])
    end

    test "no GPU leaves Reservations off entirely" do
      capture_create("/services/create")

      DockerSwarm.deploy(spec(nil))

      assert_received {:payload, payload}
      resources = payload["TaskTemplate"]["Resources"]

      assert resources["Limits"]["NanoCPUs"] == 512_000_000
      refute Map.has_key?(resources, "Reservations")
    end

    # THE failure this whole design exists to prevent. Swarm does not error on an
    # unsatisfiable reservation — the task sits pending forever with an empty error field
    # and a service that looks deployed.
    test "refuses to deploy a GPU no node advertises, instead of hanging pending" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/nodes", _opts -> {:ok, []} end)

      assert {:error, {:gpu_unschedulable, message}} =
               DockerSwarm.deploy(spec(%{"vendor" => "nvidia"}))

      # The fix lives in daemon.json, which we cannot write — so the message carries it.
      assert message =~ "node-generic-resources"
      assert message =~ "default-runtime"
      assert message =~ "pending"
    end

    test "refuses a resource kind the cluster does not advertise, and names the ones it does" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/nodes", _opts ->
        {:ok, [gpu_node("NVIDIA-GPU")]}
      end)

      assert {:error, {:gpu_unschedulable, message}} =
               DockerSwarm.deploy(spec(%{"vendor" => "nvidia", "kind" => "gpu"}))

      assert message =~ ~s("NVIDIA-GPU")
      assert message =~ "byte-for-byte"
    end

    test "the preflight runs BEFORE the image pull — no gigabytes spent on an unplaceable task" do
      test = self()

      stub(Homelab.Mocks.DockerClient, :get, fn "/nodes", _opts -> {:ok, []} end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts ->
        send(test, :pulled)
        :ok
      end)

      assert {:error, {:gpu_unschedulable, _}} = DockerSwarm.deploy(spec(%{"vendor" => "amd"}))

      refute_received :pulled
    end

    test "a GPU node that DOES advertise the kind is allowed through" do
      capture_create("/services/create")

      assert {:ok, "svc123"} = DockerSwarm.deploy(spec(%{"vendor" => "nvidia"}))
    end
  end
end
