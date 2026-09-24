defmodule Homelab.Repo.Migrations.AddManifestToBackupJobs do
  use Ecto.Migration

  # A restore needs the archive's plaintext digest, wrapped data key, frame size and
  # frame count. `snapshot_id` alone named a restic snapshot and carried none of that,
  # so an archive written by the built-in engine could not be read back.
  def change do
    alter table(:backup_jobs) do
      add :manifest, :map
      add :target_kind, :string
      add :archive_key, :string
    end

    create index(:backup_jobs, [:archive_key])
  end
end
