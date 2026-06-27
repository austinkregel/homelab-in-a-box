defmodule Homelab.Repo.Migrations.CreateReleases do
  use Ecto.Migration

  def change do
    create table(:releases) do
      add :tenant_id, references(:tenants, on_delete: :restrict), null: false
      add :app_template_id, references(:app_templates, on_delete: :restrict), null: false
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "planning"
      add :lease_owner, :string
      add :lease_expires_at, :utc_datetime
      add :plan, :map, default: %{}
      add :error_message, :text

      timestamps()
    end

    create index(:releases, [:deployment_id])
    create index(:releases, [:status])

    # At most one in-flight release per deployment.
    create unique_index(:releases, [:deployment_id],
             where: "status IN ('planning', 'provisioning', 'rolling_back')",
             name: :releases_one_active_per_deployment
           )
  end
end
