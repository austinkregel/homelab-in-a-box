defmodule Homelab.Orchestrators.RegistryAuthTest do
  @moduledoc """
  Verifies both orchestrators attach `X-Registry-Auth` for self-hosted registry
  images (so Swarm workers can pull) and omit it for public images.
  """
  # async: false — mutates :homelab application env (base_domain, creds).
  use ExUnit.Case, async: false

  import Mox

  alias Homelab.Orchestrators.{DockerEngine, DockerSwarm}

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)

    prev_domain = Application.get_env(:homelab, :base_domain)
    prev_creds = Application.get_env(:homelab, :registry_credentials)
    Application.put_env(:homelab, :base_domain, "example.com")
    Application.put_env(:homelab, :registry_credentials, {"bob", "s3cret"})

    on_exit(fn ->
      restore(:base_domain, prev_domain)
      restore(:registry_credentials, prev_creds)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, val), do: Application.put_env(:homelab, key, val)

  defp has_auth?(opts),
    do: Enum.any?(Keyword.get(opts, :headers, []), &match?({"X-Registry-Auth", _}, &1))

  @registry_image "registry.example.com/homelab-built/app:1.0"

  defp swarm_spec(image) do
    %{
      service_name: "svc",
      image: image,
      env: %{},
      volumes: [],
      network: "net",
      ports: [],
      labels: %{"homelab.managed" => "true"},
      replicas: 1,
      memory_limit: 268_435_456,
      cpu_limit: 512_000_000
    }
  end

  defp engine_spec(image) do
    %{
      service_name: "app",
      image: image,
      network: "net",
      env: %{},
      labels: %{},
      memory_limit: 268_435_456,
      cpu_limit: 512_000_000,
      volumes: [],
      ports: []
    }
  end

  describe "DockerSwarm" do
    test "attaches X-Registry-Auth on pull and service-create for registry images" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, opts ->
        send(test_pid, {:pull_opts, opts})
        :ok
      end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", _body, opts ->
        send(test_pid, {:create_opts, opts})
        {:ok, %{"ID" => "svc1"}}
      end)

      assert {:ok, "svc1"} = DockerSwarm.deploy(swarm_spec(@registry_image))

      assert_received {:pull_opts, pull_opts}
      assert has_auth?(pull_opts)
      assert_received {:create_opts, create_opts}
      assert has_auth?(create_opts)
    end

    test "omits X-Registry-Auth for public images" do
      test_pid = self()
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _p, _o -> :ok end)

      expect(Homelab.Mocks.DockerClient, :post, fn "/services/create", _body, opts ->
        send(test_pid, {:create_opts, opts})
        {:ok, %{"ID" => "svc1"}}
      end)

      assert {:ok, "svc1"} = DockerSwarm.deploy(swarm_spec("nginx:latest"))
      assert_received {:create_opts, create_opts}
      refute has_auth?(create_opts)
    end
  end

  describe "DockerEngine" do
    test "attaches X-Registry-Auth on pull for registry images" do
      test_pid = self()
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, opts ->
        send(test_pid, {:pull_opts, opts})
        :ok
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "cid"}}
          true -> {:ok, %{}}
        end
      end)

      assert {:ok, "cid"} = DockerEngine.deploy(engine_spec(@registry_image))
      assert_received {:pull_opts, pull_opts}
      assert has_auth?(pull_opts)
    end

    test "skips the pull entirely for bare homelab-built images" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts ->
        flunk("no pull should happen for a bare homelab-built image")
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          String.starts_with?(path, "/containers/create") -> {:ok, %{"Id" => "cid"}}
          true -> {:ok, %{}}
        end
      end)

      assert {:ok, "cid"} = DockerEngine.deploy(engine_spec("homelab-built/app:1.0"))
    end
  end
end
