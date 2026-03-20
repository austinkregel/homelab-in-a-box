defmodule Homelab.Repo.Migrations.CreateTenants do
  use Ecto.Migration

  def change do
    create table(:tenants) do
      add :name, :string, null: false
      add :slug, :string, null: false
      add :status, :string, null: false, default: "active"
      add :settings, :map, default: %{}

      timestamps()
    end

    create unique_index(:tenants, [:slug])
    create index(:tenants, [:status])
  end
end
