defmodule Homelab.Repo.Migrations.CreateActivityLogs do
  use Ecto.Migration

  def change do
    create table(:activity_logs) do
      add :user_id, references(:users, on_delete: :nilify_all)
      add :action, :string, null: false
      add :resource_type, :string, null: false
      add :resource_id, :integer
      add :metadata, :map, default: %{}
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:activity_logs, [:user_id])
    create index(:activity_logs, [:resource_type])
    create index(:activity_logs, [:inserted_at])
  end
end
