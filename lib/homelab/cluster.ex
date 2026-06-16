defmodule Homelab.Cluster do
  @moduledoc """
  Swarm node registry and cluster health (§D). Full preflight UI deferred;
  records local manager when swarm is active.
  """

  alias Homelab.Repo
  alias Homelab.Cluster.Node

  @swarm_degraded_key :homelab_swarm_degraded

  def swarm_degraded?, do: Process.get(@swarm_degraded_key, false)

  def set_swarm_degraded!(value) when is_boolean(value),
    do: Process.put(@swarm_degraded_key, value)

  def list_nodes, do: Repo.all(Node)

  def upsert_local_manager(hostname \\ default_hostname()) do
    attrs = %{
      hostname: hostname,
      role: "manager",
      site_label: "primary",
      status: "online",
      last_heartbeat_at: DateTime.utc_now()
    }

    case Repo.get_by(Node, hostname: hostname) do
      nil -> %Node{} |> Node.changeset(attrs) |> Repo.insert()
      node -> node |> Node.changeset(attrs) |> Repo.update()
    end
  end

  defp default_hostname do
    {:ok, name} = :inet.gethostname()
    to_string(name)
  end
end
