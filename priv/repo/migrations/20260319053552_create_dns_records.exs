defmodule Homelab.Repo.Migrations.CreateDnsRecords do
  use Ecto.Migration

  def change do
    create table(:dns_records) do
      add :dns_zone_id, references(:dns_zones, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :type, :string, null: false
      add :value, :string, null: false
      add :ttl, :integer, null: false, default: 300
      add :scope, :string, null: false, default: "public"
      add :provider_record_id, :string
      add :managed, :boolean, null: false, default: true
      add :deployment_id, references(:deployments, on_delete: :nilify_all)

      timestamps()
    end

    create index(:dns_records, [:dns_zone_id])
    create index(:dns_records, [:deployment_id])
    create index(:dns_records, [:scope])
    create index(:dns_records, [:type])
  end
end
