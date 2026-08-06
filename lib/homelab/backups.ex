defmodule Homelab.Backups do
  @moduledoc """
  Context for managing backup jobs and orchestrating backups.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Backups.BackupJob
  alias Homelab.Deployments.PermanentHome

  def list_backup_jobs do
    BackupJob
    |> preload(deployment: [:tenant, :app_template])
    |> order_by(desc: :scheduled_at)
    |> Repo.all()
  end

  @doc """
  Backup jobs belonging to one tenant, via their deployments.

  `list_backup_jobs/0` is every tenant's jobs; that is right for the operator's own
  views, and wrong for anything addressed by an API caller. There is no `tenant_id` on
  `backup_jobs` — the tenant is reached through the deployment, so the scope has to be a
  join rather than a `where`.
  """
  def list_backup_jobs_for_tenant(tenant_id) do
    BackupJob
    |> join(:inner, [b], d in assoc(b, :deployment))
    |> where([_b, d], d.tenant_id == ^tenant_id)
    |> preload(deployment: [:tenant, :app_template])
    |> order_by([b], desc: b.scheduled_at)
    |> Repo.all()
  end

  @doc """
  One backup job, but only if it belongs to this tenant.

  Returns `{:error, :not_found}` for a job that exists under a different tenant — a
  caller must not be able to tell "not yours" from "does not exist", and every consumer
  of this already turns `:not_found` into a 404.
  """
  def get_backup_job_for_tenant(tenant_id, id) do
    BackupJob
    |> join(:inner, [b], d in assoc(b, :deployment))
    |> where([b, d], b.id == ^id and d.tenant_id == ^tenant_id)
    |> preload(deployment: [:tenant, :app_template])
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      job -> {:ok, job}
    end
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

  @doc """
  Runs a backup job through the configured provider.

  The source path used to be a hardcoded `/data/tenants/<tenant>/<app>` — a directory
  nothing in this codebase ever creates. Managed data lives under
  `PermanentHome.managed_root/0`, which is an operator-editable setting (Settings →
  Storage), so the literal was not merely wrong, it ignored a value already plumbed
  through and configurable. The repo was likewise a bare relative name rather than the
  provider's configured repository.

  `size_bytes` was written as a literal `0` on every success. `format_size(0)` renders
  "—", so the Size column could never show anything — and worse, `0` is what an EMPTY
  backup would report, making the two indistinguishable. It is `nil` now, which means
  "not reported" honestly. The provider contract returns only a snapshot id, so making
  this a real number needs `backup/3` to surface restic's `total_bytes_processed`; that
  is a contract change and is deliberately not bundled here.
  """
  def execute_backup(%BackupJob{} = job) do
    backup_provider = Homelab.Config.backup_provider()
    deployment = Repo.preload(job, deployment: [:tenant, :app_template]).deployment

    with {:ok, updated_job} <- start_backup(job),
         source_path = backup_source_path(deployment),
         repo = backup_repo(),
         tags = ["deployment:#{deployment.id}", "app:#{deployment.app_template.slug}"],
         {:ok, snapshot_id} <- backup_provider.backup(source_path, repo, tags) do
      complete_backup(updated_job, snapshot_id, nil)
    else
      {:error, reason} ->
        fail_backup(job, inspect(reason))
    end
  end

  # Where this deployment's managed data actually is.
  #
  # Was `/data/tenants/<tenant>/<app>` — a directory nothing in this codebase creates.
  # `PermanentHome.backing_dir/2` is per-MOUNT, so a whole-deployment backup takes the
  # service directory that contains every mount's backing dir.
  defp backup_source_path(deployment) do
    PermanentHome.service_dir(deployment.app_template.slug)
  end

  # The provider's CONFIGURED repository, not a per-tenant relative name that was almost
  # certainly never `restic init`'d. Restic resolves a relative repo against the process
  # cwd, so `homelab-<tenant>` was not even a stable location.
  defp backup_repo do
    Application.get_env(:homelab, Homelab.BackupProviders.Restic, [])
    |> Keyword.get(:repo, "/backups/restic-repo")
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
         job = Repo.preload(job, deployment: :app_template),
         backup_provider = Homelab.Config.backup_provider(),
         :ok <- backup_provider.restore(job.snapshot_id, restore_target(job)) do
      :ok
    end
  end

  # Restores INTO the deployment's own managed directory, not a hardcoded `/data/restore`
  # scratch path that no container ever mounts — restoring there succeeded and put the
  # data nowhere useful, while the UI flashed "restore completed successfully".
  defp restore_target(%BackupJob{deployment: %{app_template: %{slug: slug}}}),
    do: PermanentHome.service_dir(slug)

  defp restore_target(_job), do: PermanentHome.managed_root()
end
