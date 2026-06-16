defmodule Homelab.Backups.BackupJob do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :completed, :failed]
  @tiers ~w(local_snapshot restic_lan zfs_replicate restic_offsite)a

  schema "backup_jobs" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :tier, Ecto.Enum, values: @tiers
    field :provider_driver_id, :string
    field :target_ref, :map
    field :capture_metadata, :map
    field :scheduled_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :snapshot_id, :string
    field :size_bytes, :integer
    field :error_message, :string

    belongs_to :deployment, Homelab.Deployments.Deployment
    belongs_to :parent_job, Homelab.Backups.BackupJob

    timestamps()
  end

  @required_fields ~w(deployment_id scheduled_at)a

  @optional_fields ~w(status tier provider_driver_id parent_job_id target_ref capture_metadata
                      started_at completed_at snapshot_id size_bytes error_message)a

  def changeset(backup_job, attrs) do
    backup_job
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:deployment_id)
  end

  def start_changeset(backup_job) do
    backup_job
    |> cast(%{status: :running, started_at: DateTime.utc_now()}, [:status, :started_at])
  end

  def complete_changeset(backup_job, capture_id, size_bytes, metadata \\ %{}) do
    backup_job
    |> cast(
      %{
        status: :completed,
        completed_at: DateTime.utc_now(),
        snapshot_id: capture_id,
        size_bytes: size_bytes,
        capture_metadata: metadata
      },
      [:status, :completed_at, :snapshot_id, :size_bytes, :capture_metadata]
    )
  end

  def fail_changeset(backup_job, error_message) do
    backup_job
    |> cast(
      %{status: :failed, completed_at: DateTime.utc_now(), error_message: error_message},
      [:status, :completed_at, :error_message]
    )
  end
end
