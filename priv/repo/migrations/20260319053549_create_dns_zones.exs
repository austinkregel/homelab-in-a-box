defmodule Homelab.Repo.Migrations.CreateDnsZones do
  use Ecto.Migration

  def change do
    create table(:dns_zones) do
      add :name, :string, null: false
      add :provider, :string, null: false, default: "manual"
      add :provider_zone_id, :string
      add :sync_status, :string, null: false, default: "pending"
      add :last_synced_at, :utc_datetime

      timestamps()
    end

    create unique_index(:dns_zones, [:name])
    create index(:dns_zones, [:provider])
  end
end
