defmodule Homelab.Cluster.Node do
  use Ecto.Schema
  import Ecto.Changeset

  schema "nodes" do
    field :hostname, :string
    field :swarm_node_id, :string
    field :role, :string, default: "worker"
    field :site_label, :string, default: "primary"
    field :tunnel_address, :string
    field :status, :string, default: "unknown"
    field :last_heartbeat_at, :utc_datetime

    has_many :node_datasets, Homelab.Cluster.NodeDataset

    timestamps()
  end

  def changeset(node, attrs) do
    node
    |> cast(attrs, [
      :hostname,
      :swarm_node_id,
      :role,
      :site_label,
      :tunnel_address,
      :status,
      :last_heartbeat_at
    ])
    |> validate_required([:hostname])
    |> unique_constraint(:hostname)
  end
end
