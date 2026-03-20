defmodule Homelab.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :sub, :string, null: false
      add :email, :string, null: false
      add :name, :string
      add :avatar_url, :string
      add :role, :string, null: false, default: "member"
      add :last_login_at, :utc_datetime

      timestamps()
    end

    create unique_index(:users, [:sub])
    create unique_index(:users, [:email])
  end
end
