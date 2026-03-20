defmodule Homelab.Repo.Migrations.CreateBackupJobs do
  use Ecto.Migration

  def change do
    create table(:backup_jobs) do
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :status, :string, null: false, default: "pending"
      add :scheduled_at, :utc_datetime, null: false
      add :started_at, :utc_datetime
      add :completed_at, :utc_datetime
      add :snapshot_id, :string
      add :size_bytes, :bigint
      add :error_message, :text

      timestamps()
    end

    create index(:backup_jobs, [:deployment_id])
    create index(:backup_jobs, [:status])
    create index(:backup_jobs, [:scheduled_at])
  end
end
