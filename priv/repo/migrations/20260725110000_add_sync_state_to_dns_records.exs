defmodule Homelab.Repo.Migrations.AddSyncStateToDnsRecords do
  use Ecto.Migration

  # Whether this record actually reached its DNS provider.
  #
  # `push_record_to_provider/1` was an `Enum.each` with three `-> :ok` discards: an
  # expired Cloudflare token, a 403, a wrong zone id, or no provider configured for the
  # scope at all — every one of them collapsed to `:ok`, and the UI flashed "DNS record
  # created!". There was no field that could hold the truth, so a record that never left
  # the box rendered identically to one serving traffic. The operator finds out when the
  # name does not resolve.
  #
  # Both columns are additive and nullable: NULL means "written before this existed, sync
  # state unknown", which is honest for existing rows rather than claiming success.
  # Migrations here run inside the boot supervisor with no manual escape hatch, so this
  # is deliberately a plain column add with no default and no index.
  def change do
    alter table(:dns_records) do
      add :last_synced_at, :utc_datetime
      add :last_sync_error, :string
    end
  end
end
