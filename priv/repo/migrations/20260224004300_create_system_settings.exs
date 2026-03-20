defmodule Homelab.Repo.Migrations.CreateSystemSettings do
  use Ecto.Migration

  def change do
    create table(:system_settings) do
      add :key, :string, null: false
      add :value, :text
      add :encrypted, :boolean, null: false, default: false
      add :category, :string, null: false, default: "general"

      timestamps()
    end

    create unique_index(:system_settings, [:key])
    create index(:system_settings, [:category])
  end
end
