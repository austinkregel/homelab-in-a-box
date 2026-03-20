defmodule Homelab.Repo.Migrations.CreateAppTemplates do
  use Ecto.Migration

  def change do
    create table(:app_templates) do
      add :slug, :string, null: false
      add :name, :string, null: false
      add :description, :text
      add :version, :string, null: false
      add :image, :string, null: false
      add :exposure_mode, :string, null: false, default: "sso_protected"
      add :auth_integration, :boolean, null: false, default: true
      add :default_env, :map, default: %{}
      add :required_env, {:array, :string}, default: []
      add :volumes, {:array, :map}, default: []
      add :ports, {:array, :map}, default: []
      add :resource_limits, :map, default: %{}
      add :backup_policy, :map, default: %{}
      add :health_check, :map, default: %{}
      add :depends_on, {:array, :string}, default: []

      timestamps()
    end

    create unique_index(:app_templates, [:slug])
  end
end
