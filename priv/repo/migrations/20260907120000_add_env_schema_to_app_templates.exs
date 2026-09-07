defmodule Homelab.Repo.Migrations.AddEnvSchemaToAppTemplates do
  use Ecto.Migration

  # Per-variable env description: when each key is required, what values it accepts,
  # and whether it holds a credential. Empty means `required_env` is the whole answer.
  def change do
    alter table(:app_templates) do
      add :env_schema, :map, default: %{}
    end
  end
end
