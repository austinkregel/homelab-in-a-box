defmodule Homelab.Docker.NetworkTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Docker.Network

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  defp stub_info(swarm) do
    stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{"Swarm" => swarm}} end)
  end

  describe "swarm_manager?/0" do
    test "a manager can drive swarm" do
      stub_info(%{"LocalNodeState" => "active", "ControlAvailable" => true})
      assert Network.swarm_manager?()
    end

    # THE distinction. A worker reports LocalNodeState "active" -- it IS in the swarm --
    # but the control plane lives on the managers, so /services/create, /swarm and
    # overlay-network creation all answer "This node is not a swarm manager". Keying the
    # orchestrator off membership rather than manager-ness would pick DockerSwarm on a
    # worker and then fail every single deploy.
    test "a WORKER is in the swarm but cannot drive it" do
      stub_info(%{"LocalNodeState" => "active", "ControlAvailable" => false})

      assert Network.swarm_active?(), "a worker really is an active swarm member"
      refute Network.swarm_manager?(), "but it has no control plane"
    end

    test "a daemon outside a swarm is neither" do
      stub_info(%{"LocalNodeState" => "inactive"})

      refute Network.swarm_active?()
      refute Network.swarm_manager?()
    end

    test "an unreachable daemon is not a manager" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts ->
        {:error, {:connection_error, :closed}}
      end)

      refute Network.swarm_manager?()
    end
  end

  describe "attrs/0" do
    test "a manager gets an attachable overlay" do
      stub_info(%{"LocalNodeState" => "active", "ControlAvailable" => true})
      assert %{"Driver" => "overlay", "Attachable" => true} = Network.attrs()
    end

    # Creating an overlay is a control-plane call, so a worker cannot make one. The
    # network driver has to agree with the orchestrator choice: a node running plain
    # containers needs plain bridges.
    test "a worker gets a bridge, because it cannot create an overlay" do
      stub_info(%{"LocalNodeState" => "active", "ControlAvailable" => false})
      assert %{"Driver" => "bridge"} = Network.attrs()
    end

    test "a non-swarm daemon gets a bridge" do
      stub_info(%{"LocalNodeState" => "inactive"})
      assert %{"Driver" => "bridge"} = Network.attrs()
    end
  end
end
