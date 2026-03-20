defmodule HomelabWeb.Api.V1.BackupJSON do
  alias Homelab.Backups.BackupJob

  def index(%{backup_jobs: jobs}) do
    %{data: Enum.map(jobs, &data/1)}
  end

  def show(%{backup_job: job}) do
    %{data: data(job)}
  end

  defp data(%BackupJob{} = job) do
    %{
      id: job.id,
      status: job.status,
      deployment_id: job.deployment_id,
      scheduled_at: job.scheduled_at,
      started_at: job.started_at,
      completed_at: job.completed_at,
      snapshot_id: job.snapshot_id,
      size_bytes: job.size_bytes,
      error_message: job.error_message,
      inserted_at: job.inserted_at,
      updated_at: job.updated_at
    }
  end
end
