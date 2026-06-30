defmodule Homelab.Deployments.Migrate.ContainerControlTest do
  @moduledoc """
  `ContainerControl` is the live implementation of the `ContainerOps` behaviour;
  every public function delegates to `Homelab.Docker.Client`.

  The Docker client now has a test seam: `Homelab.Docker.Client` dispatches to the
  module in `Process.get(:docker_client)` (then the configured default), so a test
  can point it at `Homelab.Mocks.DockerClient` for *its own process only* and drive
  every request/response branch against canned JSON — no daemon required. The
  `:integration`-tagged tests below still exercise a real daemon when present.
  """

  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Deployments.Migrate.ContainerControl
  alias Homelab.Deployments.Migrate.ContainerOps

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "behaviour contract" do
    test "declares the ContainerOps behaviour" do
      behaviours = ContainerControl.module_info(:attributes)[:behaviour] || []
      assert ContainerOps in behaviours
    end

    test "implements every ContainerOps callback with the right arity" do
      Code.ensure_loaded!(ContainerOps)
      Code.ensure_loaded!(ContainerControl)

      for {fun, arity} <- ContainerOps.behaviour_info(:callbacks) do
        assert function_exported?(ContainerControl, fun, arity),
               "ContainerControl is missing #{fun}/#{arity} required by ContainerOps"
      end
    end

    test "exports exactly the four lifecycle ops the behaviour requires" do
      callbacks = MapSet.new(ContainerOps.behaviour_info(:callbacks))

      assert callbacks ==
               MapSet.new(
                 restart_policy: 1,
                 set_restart_policy: 2,
                 stop: 2,
                 start: 1
               )
    end
  end

  describe "restart_policy/1 (mocked daemon)" do
    test "extracts the configured policy name" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/containers/db/json", _opts ->
        {:ok, %{"HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}}}}
      end)

      assert {:ok, "always"} = ContainerControl.restart_policy("db")
    end

    test "defaults to \"no\" when the policy name is null" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"HostConfig" => %{"RestartPolicy" => %{"Name" => nil}}}}
      end)

      assert {:ok, "no"} = ContainerControl.restart_policy("db")
    end

    test "defaults to \"no\" when the body has no restart policy" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:ok, %{"HostConfig" => %{}}}
      end)

      assert {:ok, "no"} = ContainerControl.restart_policy("db")
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:not_found, %{}}}
      end)

      assert {:error, {:not_found, %{}}} = ContainerControl.restart_policy("gone")
    end
  end

  describe "set_restart_policy/2 (mocked daemon)" do
    test "POSTs the new policy to /update and returns :ok" do
      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/db/update", body, _opts ->
        assert body == %{"RestartPolicy" => %{"Name" => "no"}}
        {:ok, %{}}
      end)

      assert :ok = ContainerControl.set_restart_policy("db", "no")
    end

    test "propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert {:error, {:http_error, 500, %{}}} = ContainerControl.set_restart_policy("db", "no")
    end
  end

  describe "stop/2 and start/1 (mocked daemon)" do
    test "stop sends the SIGTERM grace period via ?t= and returns :ok" do
      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/db/stop?t=60", body, _opts ->
        assert is_nil(body)
        {:ok, %{}}
      end)

      assert :ok = ContainerControl.stop("db", 60)
    end

    test "stop treats a 304 (already stopped) as :ok" do
      expect(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts -> {:ok, :not_modified} end)

      assert :ok = ContainerControl.stop("db", 1)
    end

    test "start returns :ok" do
      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/db/start", _body, _opts ->
        {:ok, %{}}
      end)

      assert :ok = ContainerControl.start("db")
    end

    test "start propagates a client error" do
      expect(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:connection_error, :nope}} = ContainerControl.start("db")
    end
  end

  # --- Live daemon branches (excluded by default via :integration) ---
  #
  # These match the established convention in this repo (see
  # docker_swarm_test.exs / client_test.exs): hit the real Engine API and
  # tolerate a connection error so the suite stays green without Docker.

  describe "restart_policy/1 (live)" do
    @tag :integration
    test "returns {:ok, name} or a graceful error for an unknown container" do
      case ContainerControl.restart_policy("homelab-nonexistent-#{System.unique_integer()}") do
        {:ok, name} -> assert is_binary(name)
        {:error, _reason} -> :ok
      end
    end
  end

  describe "stop/2 and start/1 (live)" do
    @tag :integration
    test "are idempotent against a missing container (error, not crash)" do
      id = "homelab-nonexistent-#{System.unique_integer()}"

      assert ContainerControl.stop(id, 1) in [:ok] or
               match?({:error, _}, ContainerControl.stop(id, 1))

      assert ContainerControl.start(id) == :ok or match?({:error, _}, ContainerControl.start(id))
    end
  end
end
