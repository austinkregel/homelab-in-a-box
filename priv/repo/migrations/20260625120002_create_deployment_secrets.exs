defmodule Homelab.Repo.Migrations.CreateDeploymentSecrets do
  use Ecto.Migration

  def change do
    create table(:deployment_secrets) do
      add :deployment_id, references(:deployments, on_delete: :delete_all), null: false
      add :key, :string, null: false
      add :value, :text, null: false

      timestamps()
    end

    create unique_index(:deployment_secrets, [:deployment_id, :key])
  end
end
