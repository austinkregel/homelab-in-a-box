defmodule Homelab.Adoption.AdoptedApp do
  use Ecto.Schema
  import Ecto.Changeset

  schema "adopted_apps" do
    field :slug, :string
    field :source_path, :string
    field :size_bytes, :integer
    field :classification, :string, default: "manual_only"
    field :has_compose, :boolean, default: false
    field :container_match, :map
    field :import_status, :string, default: "discovered"
    field :imported_at, :utc_datetime
    field :import_dataset, :string
    field :runbook_markdown, :string
    field :tenant_slug, :string

    belongs_to :suggested_app_template, Homelab.Catalog.AppTemplate

    timestamps()
  end

  def changeset(app, attrs) do
    app
    |> cast(attrs, [
      :slug,
      :source_path,
      :size_bytes,
      :classification,
      :has_compose,
      :container_match,
      :suggested_app_template_id,
      :import_status,
      :imported_at,
      :import_dataset,
      :runbook_markdown,
      :tenant_slug
    ])
    |> validate_required([:slug, :source_path])
    |> unique_constraint(:source_path)
  end
end
