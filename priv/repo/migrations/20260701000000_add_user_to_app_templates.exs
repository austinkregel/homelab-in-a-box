defmodule Homelab.Repo.Migrations.AddUserToAppTemplates do
  use Ecto.Migration

  def change do
    alter table(:app_templates) do
      # Container user (uid:gid) for adopted services; nil = image default.
      add :user, :string
    end
  end
end
