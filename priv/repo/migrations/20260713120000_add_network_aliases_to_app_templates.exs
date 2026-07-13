defmodule Homelab.Repo.Migrations.AddNetworkAliasesToAppTemplates do
  use Ecto.Migration

  # An adopted container is RENAMED when the plane takes it over, so every sibling that
  # reached it by its old name (`DB_HOST=mysql`) loses it. The names it must keep
  # answering to are a property of the service, so they live on the template.
  def change do
    alter table(:app_templates) do
      add :network_aliases, {:array, :string}, default: []
    end
  end
end
