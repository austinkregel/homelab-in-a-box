defmodule Homelab.Repo.Migrations.CreateDeployments do
  use Ecto.Migration

  def change do
    create table(:deployments) do
      add :tenant_id, references(:tenants, on_delete: :restrict), null: false
      add :app_template_id, references(:app_templates, on_delete: :restrict), null: false
      add :status, :string, null: false, default: "pending"
      add :external_id, :string
      add :domain, :string
      add :env_overrides, :map, default: %{}
      add :computed_spec, :map
      add :last_reconciled_at, :utc_datetime
      add :error_message, :text

      timestamps()
    end

    create index(:deployments, [:tenant_id])
    create index(:deployments, [:app_template_id])
    create index(:deployments, [:status])
    create unique_index(:deployments, [:tenant_id, :app_template_id])
  end
end
