defmodule Homelab.Repo.Migrations.CreateDomains do
  use Ecto.Migration

  def change do
    create table(:domains) do
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :fqdn, :string, null: false
      add :exposure_mode, :string, null: false, default: "sso_protected"
      add :tls_status, :string, null: false, default: "pending"
      add :tls_expires_at, :utc_datetime

      timestamps()
    end

    create index(:domains, [:deployment_id])
    create unique_index(:domains, [:fqdn])
  end
end
