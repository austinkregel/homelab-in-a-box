defmodule Homelab.Backups.BackupJob do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :running, :completed, :failed]

  schema "backup_jobs" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :scheduled_at, :utc_datetime
    field :started_at, :utc_datetime
    field :completed_at, :utc_datetime
    field :snapshot_id, :string
    field :size_bytes, :integer
    field :error_message, :string

    # What a restore needs: the plaintext digest, the wrapped data key and the frame
    # layout. A snapshot id names an archive; it does not describe one.
    field :manifest, :map
    field :target_kind, :string
    field :archive_key, :string

    belongs_to :deployment, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(deployment_id scheduled_at)a
  @optional_fields ~w(status started_at completed_at snapshot_id size_bytes error_message
                      manifest target_kind archive_key)a

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

  def complete_changeset(backup_job, snapshot_id, size_bytes) do
    backup_job
    |> cast(
      %{
        status: :completed,
        completed_at: DateTime.utc_now(),
        snapshot_id: snapshot_id,
        size_bytes: size_bytes
      },
      [:status, :completed_at, :snapshot_id, :size_bytes]
    )
  end

  @doc """
  Marks a run completed and records the archive it produced.

  `snapshot_id` keeps carrying the archive's own id so everything that already reads it
  — the restore button's guard, the coverage view — keeps working.
  """
  def archive_changeset(backup_job, manifest, target_kind) do
    manifest = stringify(manifest)

    backup_job
    |> cast(
      %{
        status: :completed,
        completed_at: DateTime.utc_now(),
        snapshot_id: manifest["id"],
        archive_key: manifest["key"],
        size_bytes: manifest["plaintext_bytes"],
        target_kind: target_kind,
        manifest: manifest
      },
      [
        :status,
        :completed_at,
        :snapshot_id,
        :archive_key,
        :size_bytes,
        :target_kind,
        :manifest
      ]
    )
  end

  # Stored as JSON, so it comes back with string keys whatever it went in as. Writing it
  # that way keeps one shape on both sides of a round trip.
  defp stringify(%{} = map) do
    Map.new(map, fn {key, value} ->
      {to_string(key), if(is_atom(value), do: to_string(value), else: value)}
    end)
  end

  def fail_changeset(backup_job, error_message) do
    backup_job
    |> cast(
      %{status: :failed, completed_at: DateTime.utc_now(), error_message: error_message},
      [:status, :completed_at, :error_message]
    )
  end
end
