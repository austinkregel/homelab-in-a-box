defmodule Homelab.Repo.Migrations.AddDnsZoneIdToDomains do
  use Ecto.Migration

  def change do
    alter table(:domains) do
      add :dns_zone_id, references(:dns_zones, on_delete: :nilify_all)
    end

    create index(:domains, [:dns_zone_id])
  end
end
