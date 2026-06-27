defmodule Homelab.System.MetricsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.System.Metrics

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  # `collect/0` calls `collect_docker_info`, which runs the `/info` GET
  # *synchronously in the caller* (see Metrics.collect/0 -> collect_docker_info/0),
  # so the Mox expectation set here is observed by the code under test.
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "collect/0" do
    test "returns a map with expected keys" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)

      result = Metrics.collect()

      assert is_map(result)
      assert Map.has_key?(result, :cpu_percent)
      assert Map.has_key?(result, :memory_total)
      assert Map.has_key?(result, :memory_used)
      assert Map.has_key?(result, :memory_percent)
      assert Map.has_key?(result, :disk)
      assert Map.has_key?(result, :docker)
    end

    test "returns numeric cpu_percent" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_number(result.cpu_percent)
    end

    test "returns numeric memory values" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_integer(result.memory_total) or result.memory_total == 0
      assert is_integer(result.memory_used) or result.memory_used == 0
      assert is_number(result.memory_percent)
    end

    test "returns disk as a list" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_list(result.disk)
    end

    test "returns docker as a map" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_map(result.docker)
    end
  end

  describe "collect/0 docker info (mocked daemon)" do
    test "GETs /info and passes the daemon-info body through unchanged" do
      info = %{
        "ID" => "ABCD:EFGH",
        "Containers" => 7,
        "ContainersRunning" => 5,
        "ContainersPaused" => 0,
        "ContainersStopped" => 2,
        "Images" => 12,
        "ServerVersion" => "25.0.3",
        "OperatingSystem" => "Ubuntu 24.04",
        "NCPU" => 8,
        "MemTotal" => 16_000_000_000
      }

      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, info} end)

      result = Metrics.collect()

      # The collector is a pure passthrough for a map body: same map, verbatim.
      assert result.docker == info
      assert result.docker["ServerVersion"] == "25.0.3"
      assert result.docker["ContainersRunning"] == 5
    end

    test "GETs exactly the /info path (no extra query/segments)" do
      test_pid = self()

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        send(test_pid, {:docker_get, path})
        {:ok, %{"ID" => "x"}}
      end)

      Metrics.collect()

      assert_received {:docker_get, "/info"}
    end

    test "falls back to an empty map when the daemon is unreachable" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts ->
        {:error, {:connection_error, :econnrefused}}
      end)

      result = Metrics.collect()

      assert result.docker == %{}
    end

    test "falls back to an empty map on an HTTP error tuple" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert Metrics.collect().docker == %{}
    end

    test "falls back to an empty map when the body is not a map" do
      # The guard is `{:ok, info} when is_map(info)`; a non-map :ok body must not
      # leak through as the docker field.
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, "not-a-map"} end)

      assert Metrics.collect().docker == %{}
    end

    test "falls back to an empty map on an unexpected return shape" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> :unexpected end)

      assert Metrics.collect().docker == %{}
    end
  end
end
