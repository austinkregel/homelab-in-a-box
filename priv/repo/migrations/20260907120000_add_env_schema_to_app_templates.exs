defmodule Homelab.Repo.Migrations.AddEnvSchemaToAppTemplates do
  use Ecto.Migration

  # Per-variable description of a template's environment: when each key is required,
  # what values it accepts, and whether it holds a credential. `required_env` is a flat
  # array, so it can only say "always" — which forced an OpenVPN operator to invent
  # WireGuard keys to satisfy gluetun's entry.
  #
  # Defaults to an empty map so existing rows read as "the flat list is the whole story".
  def change do
    alter table(:app_templates) do
      add :env_schema, :map, default: %{}
    end
  end
end
