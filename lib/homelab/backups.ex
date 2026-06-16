defmodule Homelab.Backups do
  @moduledoc """
  Context for managing backup jobs, schedules, and multi-tier backups.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Backups.{BackupJob, BackupSchedule, Providers, TargetSpec}

  # --- Backup jobs (existing API) ---

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

  def complete_backup(%BackupJob{} = job, capture_id, size_bytes, metadata \\ %{}) do
    job
    |> BackupJob.complete_changeset(capture_id, size_bytes, metadata)
    |> Repo.update()
  end

  def fail_backup(%BackupJob{} = job, error_message) do
    job
    |> BackupJob.fail_changeset(error_message)
    |> Repo.update()
  end

  def delete_backup_job(%BackupJob{} = job) do
    Repo.delete(job)
  end

  # --- Schedules ---

  def list_schedules_for_deployment(deployment_id) do
    BackupSchedule
    |> where(deployment_id: ^deployment_id)
    |> Repo.all()
  end

  def list_enabled_schedules do
    BackupSchedule
    |> where(enabled: true)
    |> preload(:deployment)
    |> Repo.all()
  end

  def upsert_schedule(attrs) do
    deployment_id = attrs["deployment_id"] || attrs[:deployment_id]
    tier = attrs["tier"] || attrs[:tier]

    case Repo.get_by(BackupSchedule, deployment_id: deployment_id, tier: tier) do
      nil ->
        %BackupSchedule{} |> BackupSchedule.changeset(attrs) |> Repo.insert()

      existing ->
        existing |> BackupSchedule.changeset(attrs) |> Repo.update()
    end
  end

  @doc """
  Creates pending backup jobs for enabled schedules whose cadence is due.
  Called from `Homelab.Services.BackupScheduler` on each tick.
  """
  def enqueue_due_scheduled_backups(now \\ DateTime.utc_now()) do
    list_enabled_schedules()
    |> Enum.filter(&schedule_due?(&1, now))
    |> Enum.map(&enqueue_from_schedule(&1, now))
  end

  defp schedule_due?(schedule, _now) do
    # Until cron parsing is added, run at most once per 24h per schedule
    case schedule.last_run_at do
      nil -> true
      last -> DateTime.diff(DateTime.utc_now(), last, :hour) >= 24
    end
  end

  defp enqueue_from_schedule(schedule, now) do
    attrs = %{
      deployment_id: schedule.deployment_id,
      tier: schedule.tier,
      provider_driver_id: schedule.provider_driver_id,
      target_ref: schedule.target_ref,
      scheduled_at: now,
      status: :pending
    }

    with {:ok, job} <- create_backup_job(attrs),
         {:ok, _} <-
           schedule
           |> Ecto.Changeset.change(%{last_run_at: now})
           |> Repo.update() do
      {:ok, job}
    end
  end

  # --- Execution ---

  def execute_backup(%BackupJob{} = job) do
    if job.tier do
      execute_backup_v2(job)
    else
      execute_backup_v1(job)
    end
  end

  defp execute_backup_v2(%BackupJob{} = job) do
    deployment = Repo.preload(job, deployment: [:tenant, :app_template]).deployment

    with {:ok, provider} <- Providers.get(job.tier),
         {:ok, target} <- decode_job_target(job),
         {:ok, updated_job} <- start_backup(job),
         opts <- backup_opts(deployment, job),
         {:ok, handle} <- provider.capture(target, opts),
         metadata <- Map.get(handle, :metadata, %{}) do
      complete_backup(updated_job, handle.id, Map.get(metadata, :bytes_added, 0), metadata)
    else
      {:error, reason} ->
        fail_backup(job, format_error(reason))
        {:error, reason}
    end
  end

  defp execute_backup_v1(%BackupJob{} = job) do
    backup_provider = Homelab.Config.backup_provider()
    deployment = Repo.preload(job, deployment: [:tenant, :app_template]).deployment

    if backup_provider do
      with {:ok, updated_job} <- start_backup(job),
           source_path <- legacy_source_path(deployment),
           repo = "homelab-#{deployment.tenant.slug}",
           tags = legacy_tags(deployment),
           {:ok, snapshot_id} <- backup_provider.backup(source_path, repo, tags) do
        complete_backup(updated_job, snapshot_id, 0)
      else
        {:error, reason} ->
          fail_backup(job, inspect(reason))
          {:error, reason}
      end
    else
      fail_backup(job, "no backup provider configured")
      {:error, :no_provider}
    end
  end

  @doc """
  Restores a backup job. Pass `target_path` in opts for v2 restores.
  """
  def restore_backup(backup_id, opts \\ [])

  def restore_backup(backup_id, opts) when is_binary(backup_id) do
    case Integer.parse(backup_id) do
      {id, ""} -> restore_backup(id, opts)
      _ -> {:error, :invalid_id}
    end
  end

  def restore_backup(backup_id, opts) when is_integer(backup_id) do
    with {:ok, job} <- get_backup_job(backup_id) do
      if job.tier do
        restore_backup_v2(job, opts)
      else
        restore_backup_v1(job, opts)
      end
    end
  end

  defp restore_backup_v2(job, opts) do
    target_path = Keyword.get_lazy(opts, :target_path, fn -> default_restore_path(job) end)
    into = {:bind_mount_path, target_path}
    handle = job_to_handle(job)

    with {:ok, provider} <- Providers.get(job.tier),
         {:ok, _} <- provider.restore(handle, into, restore_opts(job, opts)) do
      :ok
    end
  end

  defp restore_backup_v1(job, opts) do
    target_path = Keyword.get(opts, :target_path, "/tmp/homelab-restore")

    with backup_provider when not is_nil(backup_provider) <- Homelab.Config.backup_provider(),
         :ok <- backup_provider.restore(job.snapshot_id, target_path) do
      :ok
    else
      nil -> {:error, :no_provider}
      err -> err
    end
  end

  defp decode_job_target(%BackupJob{target_ref: ref}) when is_map(ref) do
    TargetSpec.decode(ref)
  end

  defp decode_job_target(_), do: {:error, :missing_target_ref}

  defp backup_opts(deployment, job) do
    tenant = deployment.tenant
    template = deployment.app_template

    tags = [
      "deployment:#{deployment.id}",
      "app:#{template.slug}",
      "tier:#{job.tier}"
    ]

    [
      tenant_slug: tenant.slug,
      tags: tags
    ]
  end

  defp job_to_handle(job) do
    %{
      provider: Providers.get(job.tier) |> elem_ok(),
      tier: job.tier,
      id: job.snapshot_id,
      created_at: job.completed_at || job.started_at || DateTime.utc_now(),
      metadata: job.capture_metadata || %{}
    }
  end

  defp elem_ok({:ok, v}), do: v
  defp elem_ok(_), do: nil

  defp restore_opts(job, opts) do
    deployment = Repo.preload(job, :deployment).deployment
    tenant_slug = deployment && deployment.tenant && deployment.tenant.slug
    Keyword.merge([tenant_slug: tenant_slug], opts)
  end

  defp default_restore_path(job) do
    deployment = Repo.preload(job, deployment: [:app_template]).deployment
    slug = deployment.app_template.slug
    ts = DateTime.utc_now() |> DateTime.to_unix()
    "/tmp/homelab-restores/#{slug}-#{ts}"
  end

  defp legacy_source_path(deployment) do
    # Legacy v1 path (incorrect for docker volumes); kept for old jobs only.
    "/data/tenants/#{deployment.tenant.slug}/#{deployment.app_template.slug}"
  end

  defp legacy_tags(deployment) do
    ["deployment:#{deployment.id}", "app:#{deployment.app_template.slug}"]
  end

  defp format_error(:storage_unavailable),
    do: "ZFS storage is not available on this host (install ZFS and homelab-zfs-agent when ready)"

  defp format_error(:not_implemented), do: "This backup tier is not implemented yet"
  defp format_error(reason), do: inspect(reason)

  @doc "Builds a default restic_lan target_ref for a deployment using bind-mount discovery."
  def default_restic_lan_target_ref(deployment) do
    path = Homelab.Adoption.legacy_appdata_path(deployment.app_template.slug)
    TargetSpec.encode({:bind_mount_path, path})
  end
end
