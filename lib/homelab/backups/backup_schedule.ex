defmodule Homelab.Backups.BackupSchedule do
  use Ecto.Schema
  import Ecto.Changeset

  @tiers ~w(local_snapshot restic_lan zfs_replicate restic_offsite)a

  schema "backup_schedules" do
    field :tier, Ecto.Enum, values: @tiers
    field :provider_driver_id, :string
    field :enabled, :boolean, default: true
    field :cadence_cron, :string
    field :target_ref, :map
    field :retention_policy, :map, default: %{}
    field :last_run_at, :utc_datetime

    belongs_to :deployment, Homelab.Deployments.Deployment

    timestamps()
  end

  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [
      :deployment_id,
      :tier,
      :provider_driver_id,
      :enabled,
      :cadence_cron,
      :target_ref,
      :retention_policy,
      :last_run_at
    ])
    |> validate_required([:deployment_id, :tier, :provider_driver_id, :target_ref])
    |> foreign_key_constraint(:deployment_id)
    |> unique_constraint([:deployment_id, :tier])
  end
end
