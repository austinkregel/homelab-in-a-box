defmodule Homelab.InfrastructureTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Infrastructure

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "available_services/0" do
    test "returns a list of system service templates" do
      services = Infrastructure.available_services()
      assert is_list(services)
      assert length(services) > 0

      keys = Enum.map(services, & &1.key)
      assert "traefik" in keys
      assert "pihole" in keys
    end

    test "each service has key, name, and image" do
      for service <- Infrastructure.available_services() do
        assert Map.has_key?(service, :key)
        assert Map.has_key?(service, :name)
        assert Map.has_key?(service, :image)
        assert is_binary(service.name)
        assert is_binary(service.image)
      end
    end
  end

  describe "provision_service/1" do
    test "returns error for unknown service key" do
      assert {:error, :unknown_service} = Infrastructure.provision_service("nonexistent")
    end
  end

  describe "list_system_services/0 (mocked daemon)" do
    test "parses id/name/image/state and the system role label" do
      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        # Filters by the homelab.system=true label.
        assert path =~ "/containers/json?all=true&filters="
        assert path =~ URI.encode_www_form(Jason.encode!(%{"label" => ["homelab.system=true"]}))

        {:ok,
         [
           %{
             "Id" => "abc123",
             "Names" => ["/homelab-traefik"],
             "Image" => "traefik:v3.6",
             "State" => "running",
             "Labels" => %{
               "homelab.system" => "true",
               "homelab.system.role" => "reverse-proxy"
             }
           },
           %{
             "Id" => "def456",
             "Names" => ["/homelab-pihole"],
             "Image" => "pihole/pihole:latest",
             "State" => "exited",
             "Labels" => %{"homelab.system" => "true"}
           }
         ]}
      end)

      assert {:ok, services} = Infrastructure.list_system_services()

      assert services == [
               %{
                 id: "abc123",
                 name: "homelab-traefik",
                 image: "traefik:v3.6",
                 status: "running",
                 role: "reverse-proxy"
               },
               %{
                 id: "def456",
                 name: "homelab-pihole",
                 image: "pihole/pihole:latest",
                 status: "exited",
                 role: "unknown"
               }
             ]
    end

    test "strips the leading slash off the first container name" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         [
           %{
             "Id" => "x",
             "Names" => ["/homelab-traefik", "/alias"],
             "Image" => "img",
             "State" => "running",
             "Labels" => %{"homelab.system.role" => "reverse-proxy"}
           }
         ]}
      end)

      assert {:ok, [%{name: "homelab-traefik"}]} = Infrastructure.list_system_services()
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = Infrastructure.list_system_services()
    end
  end

  describe "provision_service/1 (mocked daemon)" do
    test "no-op when the container is already running (network exists)" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/networks/homelab-internal" -> {:ok, %{"Name" => "homelab-internal"}}
          "/containers/homelab-pihole/json" -> {:ok, %{"State" => %{"Running" => true}}}
        end
      end)

      assert {:ok, :already_running} = Infrastructure.provision_service("pihole")
    end

    test "creates the network when missing, then provisions" do
      # Network 404 -> create; container already running afterwards.
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/networks/homelab-internal" -> {:error, {:not_found, %{}}}
          "/containers/homelab-pihole/json" -> {:ok, %{"State" => %{"Running" => true}}}
        end
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/networks/create", body, _opts ->
        assert body == %{"Name" => "homelab-internal", "Driver" => "bridge"}
        {:ok, %{"Id" => "net1"}}
      end)

      assert {:ok, :already_running} = Infrastructure.provision_service("pihole")
    end

    test "propagates a network creation failure as :network_create_failed" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/networks/homelab-internal", _opts ->
        {:error, {:not_found, %{}}}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/networks/create", _body, _opts ->
        {:error, :boom}
      end)

      assert {:error, {:network_create_failed, :boom}} =
               Infrastructure.provision_service("pihole")
    end

    test "404 on container inspect -> pulls image, creates and starts the container" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/networks/homelab-internal" -> {:ok, %{}}
          "/containers/homelab-pihole/json" -> {:error, {:not_found, %{}}}
        end
      end)

      expect(Homelab.Mocks.DockerClient, :post_stream, fn path, _opts ->
        assert path =~ "/images/create?fromImage="
        :ok
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        case path do
          "/containers/create?name=homelab-pihole" ->
            assert body["Image"] == "pihole/pihole:latest"
            assert body["HostConfig"]["NetworkMode"] == "homelab-internal"
            assert body["HostConfig"]["RestartPolicy"] == %{"Name" => "unless-stopped"}
            {:ok, %{"Id" => "newid"}}

          "/containers/homelab-pihole/start" ->
            {:ok, %{}}
        end
      end)

      assert {:ok, :started} = Infrastructure.provision_service("pihole")
    end

    test "existing-but-stopped container is started in place" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/networks/homelab-internal" -> {:ok, %{}}
          "/containers/homelab-pihole/json" -> {:ok, %{"State" => %{"Running" => false}}}
        end
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/homelab-pihole/start",
                                                   _body,
                                                   _opts ->
        {:ok, %{}}
      end)

      assert {:ok, :started} = Infrastructure.provision_service("pihole")
    end

    test "start failure on a stale container -> force-delete then recreate" do
      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        case path do
          "/networks/homelab-internal" -> {:ok, %{}}
          "/containers/homelab-pihole/json" -> {:ok, %{"State" => %{"Running" => false}}}
        end
      end)

      expect(Homelab.Mocks.DockerClient, :delete, fn "/containers/homelab-pihole?force=true",
                                                     _opts ->
        {:ok, %{}}
      end)

      expect(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        case path do
          # First start attempt fails -> triggers recreate path.
          "/containers/homelab-pihole/start" -> {:error, :start_failed}
          "/containers/create?name=homelab-pihole" -> {:ok, %{"Id" => "recreated"}}
        end
      end)

      # After delete+recreate, create_system_container issues its own start; but the
      # routed stub above returns {:error, :start_failed} for every start, so the
      # recreate's start fails and the create path returns {:create_failed, ...}.
      assert {:error, {:create_failed, :start_failed}} =
               Infrastructure.provision_service("pihole")
    end
  end

  describe "connect_traefik_to_network/1 (mocked daemon)" do
    test "connects when Traefik is not already on the network" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/homelab-traefik/json", _opts ->
        {:ok,
         %{
           "Id" => "traefik-id",
           "NetworkSettings" => %{"Networks" => %{"homelab-internal" => %{}}}
         }}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/networks/app-net/connect", body, _opts ->
        assert body == %{"Container" => "traefik-id"}
        {:ok, %{}}
      end)

      assert :ok = Infrastructure.connect_traefik_to_network("app-net")
    end

    test "is idempotent: skips POST when already connected" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         %{
           "Id" => "traefik-id",
           "NetworkSettings" => %{"Networks" => %{"app-net" => %{}}}
         }}
      end)

      # No post expectation -> verify_on_exit! fails if connect is called.
      assert :ok = Infrastructure.connect_traefik_to_network("app-net")
    end

    test "returns :ok when Traefik is not found" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert :ok = Infrastructure.connect_traefik_to_network("app-net")
    end

    test "returns :ok (swallows) on an arbitrary inspect error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, :boom}
      end)

      assert :ok = Infrastructure.connect_traefik_to_network("app-net")
    end
  end

  describe "disconnect_traefik_from_network/1 (mocked daemon)" do
    test "disconnects with Force when currently connected" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/homelab-traefik/json", _opts ->
        {:ok,
         %{
           "Id" => "traefik-id",
           "NetworkSettings" => %{"Networks" => %{"app-net" => %{}}}
         }}
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/networks/app-net/disconnect", body, _opts ->
        assert body == %{"Container" => "traefik-id", "Force" => true}
        {:ok, %{}}
      end)

      assert :ok = Infrastructure.disconnect_traefik_from_network("app-net")
    end

    test "is idempotent: skips POST when not connected" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok,
         %{
           "Id" => "traefik-id",
           "NetworkSettings" => %{"Networks" => %{"homelab-internal" => %{}}}
         }}
      end)

      assert :ok = Infrastructure.disconnect_traefik_from_network("app-net")
    end

    test "returns :ok when Traefik is not found" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert :ok = Infrastructure.disconnect_traefik_from_network("app-net")
    end
  end

  describe "traefik_networks/0 (mocked daemon)" do
    test "returns the list of connected network names" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/homelab-traefik/json", _opts ->
        {:ok,
         %{
           "NetworkSettings" => %{
             "Networks" => %{"homelab-internal" => %{}, "app-net" => %{}}
           }
         }}
      end)

      networks = Infrastructure.traefik_networks()
      assert Enum.sort(networks) == ["app-net", "homelab-internal"]
    end

    test "returns [] on error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert [] = Infrastructure.traefik_networks()
    end
  end
end
