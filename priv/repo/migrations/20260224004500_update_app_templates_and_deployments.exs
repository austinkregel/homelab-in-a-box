defmodule Homelab.Repo.Migrations.UpdateAppTemplatesAndDeployments do
  use Ecto.Migration

  def change do
    alter table(:app_templates) do
      add :source, :string, null: false, default: "seeded"
      add :source_id, :string
      add :logo_url, :string
      add :category, :string
      add :auth_mode, :string, null: false, default: "none"
    end

    drop_if_exists unique_index(:deployments, [:tenant_id, :app_template_id])
    create index(:app_templates, [:source])
    create index(:app_templates, [:category])
  end
end
