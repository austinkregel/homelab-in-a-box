defmodule Homelab.Workbench.Version do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workbench_versions" do
    field :version_number, :integer
    field :snapshot_name, :string
    field :image_digest, :string
    field :image_tag, :string
    field :notes, :string
    field :published_at, :utc_datetime
    field :published_by, :string

    belongs_to :project, Homelab.Workbench.Project

    timestamps()
  end

  def changeset(version, attrs) do
    version
    |> cast(attrs, [
      :project_id,
      :version_number,
      :snapshot_name,
      :image_digest,
      :image_tag,
      :notes,
      :published_at,
      :published_by
    ])
    |> validate_required([:project_id, :version_number, :image_digest, :published_at])
    |> unique_constraint([:project_id, :version_number])
  end
end
