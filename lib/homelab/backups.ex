defmodule Homelab.Backups do
  @moduledoc """
  Context for managing backup jobs and orchestrating backups.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Backups.BackupJob

  def list_backup_jobs do
    BackupJob
    |> preload(deployment: [:tenant, :app_template])
    |> order_by(desc: :scheduled_at)
    |> Repo.all()
  end

  def list_backup_jobs_for_deployment(deployment_id) do
    BackupJob
    |> where(deployment_id: ^deployment_id)
    |> order_by(desc: :scheduled_at)
    |> Repo.all()
  end

  def list_due_backups(now) do
    BackupJob
    |> where(status: :pending)
    |> where([b], b.scheduled_at <= ^now)
    |> preload(deployment: [:tenant, :app_template])
    |> Repo.all()
  end

  def get_backup_job(id) do
    case Repo.get(BackupJob, id) |> Repo.preload(deployment: [:tenant, :app_template]) do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
  end

  def get_backup_job!(id) do
    Repo.get!(BackupJob, id) |> Repo.preload(deployment: [:tenant, :app_template])
  end

  def create_backup_job(attrs) do
    %BackupJob{}
    |> BackupJob.changeset(attrs)
    |> Repo.insert()
  end

  def start_backup(%BackupJob{} = job) do
    job
    |> BackupJob.start_changeset()
    |> Repo.update()
  end

  def complete_backup(%BackupJob{} = job, snapshot_id, size_bytes) do
    job
    |> BackupJob.complete_changeset(snapshot_id, size_bytes)
    |> Repo.update()
  end

  def fail_backup(%BackupJob{} = job, error_message) do
    job
    |> BackupJob.fail_changeset(error_message)
    |> Repo.update()
  end

  def execute_backup(%BackupJob{} = job) do
    backup_provider = Homelab.Config.backup_provider()
    deployment = Repo.preload(job, deployment: [:tenant, :app_template]).deployment

    with {:ok, updated_job} <- start_backup(job),
         source_path = "/data/tenants/#{deployment.tenant.slug}/#{deployment.app_template.slug}",
         repo = "homelab-#{deployment.tenant.slug}",
         tags = ["deployment:#{deployment.id}", "app:#{deployment.app_template.slug}"],
         {:ok, snapshot_id} <- backup_provider.backup(source_path, repo, tags) do
      complete_backup(updated_job, snapshot_id, 0)
    else
      {:error, reason} ->
        fail_backup(job, inspect(reason))
    end
  end

  def delete_backup_job(%BackupJob{} = job) do
    Repo.delete(job)
  end

  @doc """
  Restores a backup job to the target path.
  Returns :ok on success or {:error, reason} on failure.
  """
  def restore_backup(backup_id) when is_binary(backup_id) do
    case String.to_integer(backup_id) do
      id when is_integer(id) -> restore_backup(id)
    end
  end

  def restore_backup(backup_id) when is_integer(backup_id) do
    with {:ok, job} <- get_backup_job(backup_id),
         backup_provider = Homelab.Config.backup_provider(),
         :ok <- backup_provider.restore(job.snapshot_id, "/data/restore") do
      :ok
    end
  end
end
