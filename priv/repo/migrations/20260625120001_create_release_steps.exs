defmodule Homelab.Repo.Migrations.CreateReleaseSteps do
  use Ecto.Migration

  def change do
    create table(:release_steps) do
      add :release_id, references(:releases, on_delete: :delete_all), null: false
      add :type, :string, null: false
      add :status, :string, null: false, default: "pending"
      add :position, :integer, null: false
      add :resource_handle, :map, default: %{}
      add :attempts, :integer, null: false, default: 0
      add :error_message, :text

      timestamps()
    end

    create unique_index(:release_steps, [:release_id, :position])
    create index(:release_steps, [:release_id, :status])
  end
end
