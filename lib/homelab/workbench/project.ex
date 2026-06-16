defmodule Homelab.Workbench.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "workbench_projects" do
    field :slug, :string
    field :name, :string
    field :build_dataset, :string
    field :data_dataset, :string
    field :archived_at, :utc_datetime

    belongs_to :tenant, Homelab.Tenants.Tenant
    belongs_to :app_template, Homelab.Catalog.AppTemplate

    has_many :versions, Homelab.Workbench.Version
    has_many :builds, Homelab.Workbench.Build

    timestamps()
  end

  def changeset(project, attrs) do
    project
    |> cast(attrs, [
      :tenant_id,
      :slug,
      :name,
      :app_template_id,
      :build_dataset,
      :data_dataset,
      :archived_at
    ])
    |> validate_required([:tenant_id, :slug, :name])
    |> unique_constraint([:tenant_id, :slug])
  end
end
