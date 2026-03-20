defmodule Homelab.Repo.Migrations.CreateNotifications do
  use Ecto.Migration

  def change do
    create table(:notifications) do
      add :user_id, references(:users, on_delete: :delete_all), null: true
      add :title, :string, null: false
      add :body, :text
      add :severity, :string, null: false, default: "info"
      add :read_at, :utc_datetime
      add :link, :string

      timestamps()
    end

    create index(:notifications, [:user_id])
    create index(:notifications, [:read_at])
  end
end
