defmodule Homelab.Repo.Migrations.AddStageAndReasonToReleaseSteps do
  use Ecto.Migration

  # `stage` is the lifecycle band a step belongs to (prepare … verification), NULL for
  # rows planned before stages existed; `reason_type` says what its message is.
  def up do
    alter table(:release_steps) do
      add :stage, :string
      add :reason_type, :string
    end

    rename table(:release_steps), :error_message, to: :reason_message

    execute "UPDATE release_steps SET reason_type = 'error' WHERE reason_message IS NOT NULL"
  end

  def down do
    rename table(:release_steps), :reason_message, to: :error_message

    alter table(:release_steps) do
      remove :stage
      remove :reason_type
    end
  end
end
