defmodule Homelab.Cluster.NodeDataset do
  use Ecto.Schema
  import Ecto.Changeset

  schema "node_datasets" do
    field :dataset_name, :string
    field :role, :string, default: "primary"

    belongs_to :node, Homelab.Cluster.Node

    timestamps()
  end

  def changeset(nd, attrs) do
    nd
    |> cast(attrs, [:node_id, :dataset_name, :role])
    |> validate_required([:node_id, :dataset_name])
    |> unique_constraint([:node_id, :dataset_name])
  end
end
