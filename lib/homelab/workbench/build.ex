defmodule Homelab.Workbench.Build do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workbench_builds" do
    field :status, :string, default: "pending"
    field :log, :string
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :error_message, :string

    belongs_to :project, Homelab.Workbench.Project
    belongs_to :version, Homelab.Workbench.Version

    timestamps()
  end

  def changeset(build, attrs) do
    build
    |> cast(attrs, [
      :project_id,
      :version_id,
      :status,
      :log,
      :started_at,
      :completed_at,
      :error_message
    ])
    |> validate_required([:project_id])
  end
end
