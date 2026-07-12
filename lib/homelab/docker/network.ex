defmodule Homelab.Docker.Network do
  @moduledoc """
  Creates the Docker networks workloads attach to, with a driver the daemon can
  actually use.

  The driver is not a free choice. A Swarm service can only attach to a
  swarm-scoped (overlay) network — a task may be scheduled on any node, so a
  node-local bridge is meaningless to it, and `/services/create` rejects one
  outright ("cannot be used with services"). Overlays here are always
  `Attachable`, which is what lets a *standalone* container join one too — both
  because `Homelab.Infrastructure` runs Traefik as a plain container that
  `/networks/connect`s to every published network, and because an adopted stack's
  containers are plain containers.

  That is why the driver keys off the DAEMON's swarm state rather than the
  selected orchestrator: an attachable overlay serves containers *and* services,
  so on a swarm-enabled daemon it is the right driver either way, while on a
  daemon without swarm it is not even creatable. Keying off the orchestrator
  setting would also be unusable in `Homelab.Bootstrap`, which creates the
  backbone network before the database that stores the setting exists.
  """

  require Logger

  alias Homelab.Docker.Client

  @bridge %{"Driver" => "bridge"}
  @overlay %{"Driver" => "overlay", "Attachable" => true}

  @doc """
  The `/networks/create` attributes this daemon needs: an attachable overlay when this
  node can drive Swarm, otherwise a bridge.

  Keyed off `swarm_manager?/0`, not `swarm_active?/0`. Creating an overlay is a
  control-plane call, so a WORKER — which is "active" in the swarm but has no control
  plane — cannot make one. It must agree with the orchestrator choice, which is keyed
  off the same question: a node that runs plain containers needs plain bridges.
  """
  @spec attrs() :: map()
  def attrs, do: if(swarm_manager?(), do: @overlay, else: @bridge)

  @doc """
  Ensures a system network exists (the backbone, Bootstrap's). An existing network
  is accepted whatever its driver — these carry standalone containers, which are
  happy on a bridge or on an attachable overlay.
  """
  @spec ensure(String.t()) :: :ok | {:error, term()}
  def ensure(name) do
    case inspect_network(name) do
      {:ok, _network} -> :ok
      :not_found -> create(name)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Ensures a network a workload attaches to exists *and* has a driver that workload
  can use.

  A network created before swarm was enabled is a local bridge, which Swarm
  refuses to attach a service to — and Docker cannot change a network's driver in
  place, so it has to be recreated. That is only safe while nothing is attached, so
  a network with live containers on it is reported rather than torn out from under
  them.
  """
  @spec ensure_for_workload(String.t()) :: :ok | {:error, term()}
  def ensure_for_workload(name) do
    case inspect_network(name) do
      :not_found ->
        create(name)

      {:ok, network} ->
        wanted = attrs()["Driver"]

        case network["Driver"] do
          ^wanted -> :ok
          # Recreating destroys a network, so only ever do it on a driver we
          # positively read back as wrong. A response without a `Driver` tells us
          # nothing, and "nothing" is not grounds for a teardown.
          driver when driver in [nil, ""] -> :ok
          actual -> recreate(name, network, actual, wanted)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # `LocalNodeState` is "active" on a node that has joined a swarm, and "inactive"
  # otherwise. A daemon that cannot be reached is treated as non-swarm: the caller
  # is about to fail on its own Docker call anyway, and guessing "overlay" would
  # turn that into a confusing network error instead.
  @spec swarm_active?() :: boolean()
  def swarm_active? do
    case Client.get("/info") do
      {:ok, %{"Swarm" => %{"LocalNodeState" => "active"}}} -> true
      _ -> false
    end
  end

  @doc """
  Whether this daemon can DRIVE Swarm — i.e. it is a manager.

  `swarm_active?/0` is not the same question. `LocalNodeState` is `"active"` on a
  WORKER too: the node is in the swarm, but the control plane lives on the managers,
  so `/services/create`, `/swarm` and overlay-network creation all come back with
  "This node is not a swarm manager."

  Every capability decision (which orchestrator to run, whether a network can be an
  overlay) has to key off manager-ness, not membership — otherwise homelab running on
  a worker would confidently choose the Swarm orchestrator and then fail every single
  deploy. `ControlAvailable` is the daemon's own word for "I am a manager".
  """
  @spec swarm_manager?() :: boolean()
  def swarm_manager? do
    case Client.get("/info") do
      {:ok, %{"Swarm" => %{"LocalNodeState" => "active", "ControlAvailable" => true}}} -> true
      _ -> false
    end
  end

  defp create(name) do
    body = Map.put(attrs(), "Name", name)

    case Client.post("/networks/create", body) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:network_create_failed, reason}}
    end
  end

  defp recreate(name, network, actual, wanted) do
    case attached_containers(network) do
      [] ->
        Logger.warning(
          "Network #{name} has driver #{actual} but this daemon needs #{wanted}; " <>
            "nothing is attached to it, so recreating it."
        )

        with :ok <- remove(name), do: create(name)

      attached ->
        Logger.error(
          "Network #{name} has driver #{actual} but this daemon needs #{wanted}, and " <>
            "a driver cannot be changed in place. Containers are attached to it " <>
            "(#{Enum.join(attached, ", ")}), so it is not safe to recreate automatically."
        )

        {:error, {:network_driver_mismatch, name, actual, wanted, attached}}
    end
  end

  defp remove(name) do
    case Client.delete("/networks/#{name}") do
      {:ok, _} -> :ok
      {:error, {:not_found, _}} -> :ok
      {:error, reason} -> {:error, {:network_remove_failed, name, reason}}
    end
  end

  defp attached_containers(network) do
    network
    |> Map.get("Containers")
    |> Kernel.||(%{})
    |> Map.values()
    |> Enum.map(&(&1["Name"] || ""))
    |> Enum.reject(&(&1 == ""))
  end

  defp inspect_network(name) do
    case Client.get("/networks/#{name}") do
      {:ok, network} -> {:ok, network}
      {:error, {:not_found, _}} -> :not_found
      {:error, reason} -> {:error, reason}
    end
  end
end
