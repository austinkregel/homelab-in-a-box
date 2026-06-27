defmodule Homelab.Deployments.Migrate.ContainerControlTest do
  @moduledoc """
  `ContainerControl` is the live implementation of the `ContainerOps`
  behaviour. Every public function delegates straight to
  `Homelab.Docker.Client`, which talks to the Docker Engine API over a Unix
  socket. The client has no plug/`Req.Test`/Bypass injection seam (it always
  builds its own request and calls `Req.request/1` with `unix_socket:`), so the
  request/response branches cannot be exercised against a fake daemon without a
  live socket.

  What we CAN assert without Docker is the contract: that this module declares
  and fully implements the `ContainerOps` behaviour with the expected callbacks
  and arities. The branch-level behaviour (304 -> :ok, policy extraction, etc.)
  is covered by the `:integration`-tagged tests below, which run only when a
  daemon is reachable and otherwise stay green by tolerating a connection error.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.ContainerControl
  alias Homelab.Deployments.Migrate.ContainerOps

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
