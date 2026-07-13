defmodule Homelab.Repo.Migrations.AddCommandToAppTemplates do
  use Ecto.Migration

  # What the container actually RUNS. A compose file routinely overrides it
  # (`command: minio server /data/minio ...`), and an adopted service that falls back
  # to the image default is not the service that was adopted.
  def change do
    alter table(:app_templates) do
      add :command, {:array, :string}
      add :entrypoint, {:array, :string}
    end
  end
end
