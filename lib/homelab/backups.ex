defmodule Homelab.Backups do
  @moduledoc """
  Context for managing backup jobs and orchestrating backups.
  """

  import Ecto.Query
  alias Homelab.Accounts
  alias Homelab.Backups.Archive
  alias Homelab.Backups.BackupJob
  alias Homelab.Backups.Failure
  alias Homelab.Backups.TargetConfig
  alias Homelab.Deployments.PermanentHome
  alias Homelab.Notifications
  alias Homelab.Repo
  alias Homelab.Services.ActivityLog

  @doc """
  Every deployment paired with the state of its protection.

  The Backups page listed backup *jobs*, and a job is deleted with its deployment,
  so the page went empty exactly when something had been lost. Coverage asks the
  opposite question — which apps are protected — and so always has rows to show.

  `:unprotected` means no job has ever been created, `:unverified` means jobs exist
  but none has completed, `:protected` means at least one has.
  """
  def coverage do
    jobs_by_deployment =
      BackupJob
      |> Repo.all()
      |> Enum.group_by(& &1.deployment_id)

    Homelab.Deployments.list_deployments()
    |> Enum.map(fn deployment ->
      jobs = Map.get(jobs_by_deployment, deployment.id, [])
      completed = Enum.filter(jobs, &(&1.status == :completed))

      %{
        deployment: deployment,
        jobs: jobs,
        last_completed_at:
          completed
          |> Enum.map(& &1.completed_at)
          |> Enum.reject(&is_nil/1)
          |> Enum.max(fn -> nil end),
        state:
          cond do
            completed != [] -> :protected
            jobs != [] -> :unverified
            true -> :unprotected
          end
      }
    end)
  end

  @doc """
  What is actually in the backup repository, each snapshot marked with whether a
  backup job still points at it.

  A snapshot outlives the deployment that wrote it: `destroy_deployment/1` deletes
  the `backup_jobs` rows by cascade and never touches the repository, and deleting
  a single job says so in its own flash. `:orphaned` snapshots are what that leaves
  behind — real data, still costing real space, that nothing else in the app can see.
  """
  def repo_snapshots do
    # Reading the destination touches storage that may be absent, unmounted, or
    # unreachable over the network. This is a read for a page that already renders an
    # error state; it must not take the page down with it.
    try do
      with {:ok, target, config} <- TargetConfig.resolve(),
           {:ok, objects} <- target.list(config, "") do
        {:ok, mark_orphans(objects)}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      :exit, reason -> {:error, reason}
    end
  end

  defp mark_orphans(objects) do
    known =
      BackupJob
      |> Repo.all()
      |> Enum.map(& &1.archive_key)
      |> Enum.reject(&is_nil/1)
      |> MapSet.new()

    Enum.map(objects, fn object ->
      key = Map.get(object, :key) || Map.get(object, "key")

      object
      |> Map.put(:id, key)
      |> Map.put(:state, if(MapSet.member?(known, key), do: :tracked, else: :orphaned))
    end)
  end

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
  Archives a deployment's managed data to the configured destination.

  The whole volume goes into one encrypted archive (`Homelab.Backups.Archive`), written
  to whichever destination the operator chose (`Homelab.Backups.TargetConfig`). The
  archive's manifest is stored on the row, because a restore needs the plaintext
  digest, the wrapped data key and the frame layout — none of which a snapshot id
  carries.

  `size_bytes` is the volume's real size now that the writer measures it, so the Size
  column distinguishes a small backup from an empty one.
  """
  def execute_backup(%BackupJob{} = job) do
    deployment = Repo.preload(job, deployment: [:tenant, :app_template]).deployment

    with {:ok, running_job} <- start_backup(job) do
      case attempt_backup(deployment) do
        # The outcome is recorded before it is announced, so a notification is only
        # ever raised about a row that has already settled — and an announcement that
        # fails cannot cost the result.
        {:ok, manifest, target_kind} ->
          result = record_archive(running_job, manifest, target_kind)
          announce_success(deployment)
          result

        {:error, reason} ->
          result = fail_backup(running_job, Failure.to_message(reason))
          announce_failure(deployment, reason)
          result
      end
    end
  end

  # A backup that fails on a schedule has nobody watching a flash message, and until
  # now it wrote nothing to the activity log and raised no notification — so the only
  # trace was a row in a table the page never rendered. Protection silently lapsing is
  # the one failure this feature cannot afford to keep quiet about.
  defp announce_failure(deployment, reason) do
    %{summary: summary} = Failure.describe(reason)
    label = deployment_label(deployment)

    ActivityLog.error("backups", "Backup of #{label} failed: #{summary}", %{
      deployment_id: deployment.id,
      reason: inspect(reason)
    })

    for user <- Accounts.list_admins() do
      Notifications.create(%{
        user_id: user.id,
        title: "Backup failed: #{label}",
        body: summary,
        severity: "error",
        link: "/deployments/#{deployment.id}?tab=backups"
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp announce_success(deployment) do
    ActivityLog.info("backups", "Backup of #{deployment_label(deployment)} completed", %{
      deployment_id: deployment.id
    })

    :ok
  rescue
    _ -> :ok
  end

  defp deployment_label(%{app_template: %{name: name}}) when is_binary(name), do: name
  defp deployment_label(%{id: id}), do: "deployment #{id}"

  # `managed_root/0` and the local target both raise when unconfigured rather than
  # guessing a path, so a raise here is an ordinary outcome and has to become a failed
  # job. A raise that escaped left `status: :running` with a blank error forever.
  #
  # Reasons travel as terms rather than strings so `Failure` can recognise them; an
  # `inspect` at this boundary would leave it matching on prose.
  defp attempt_backup(deployment) do
    with {:ok, target, config} <- TargetConfig.resolve(),
         source_path = backup_source_path(deployment),
         key = archive_key(deployment),
         opts = [compression: TargetConfig.compression()],
         {:ok, manifest} <- Archive.create(source_path, target, config, key, opts) do
      {:ok, manifest, target.kind()}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exited, reason}}
  end

  # One archive per run, under the service it belongs to, named so that listing the
  # destination is chronological without consulting the database.
  defp archive_key(deployment) do
    stamp =
      DateTime.utc_now() |> DateTime.truncate(:second) |> Calendar.strftime("%Y%m%dT%H%M%SZ")

    Path.join(deployment.app_template.slug, stamp)
  end

  defp record_archive(job, manifest, target_kind) do
    job
    |> BackupJob.archive_changeset(manifest, target_kind)
    |> Repo.update()
  end

  # Where this deployment's managed data actually is.
  #
  # Was `/data/tenants/<tenant>/<app>` — a directory nothing in this codebase creates.
  # `PermanentHome.backing_dir/2` is per-MOUNT, so a whole-deployment backup takes the
  # service directory that contains every mount's backing dir.
  defp backup_source_path(deployment) do
    PermanentHome.service_dir(deployment.app_template.slug)
  end

  def delete_backup_job(%BackupJob{} = job) do
    Repo.delete(job)
  end

  @doc """
  Restores an archive over the deployment's managed data.

  `Archive.extract/5` assembles the tree beside the destination and moves it in only
  once the plaintext digest matches, so a corrupt or tampered archive leaves the live
  directory untouched rather than half-overwritten.
  """
  def restore_backup(backup_id) when is_binary(backup_id) do
    case Integer.parse(backup_id) do
      {id, ""} -> restore_backup(id)
      _ -> {:error, {:invalid_backup_id, backup_id}}
    end
  end

  def restore_backup(backup_id) when is_integer(backup_id) do
    with {:ok, job} <- get_backup_job(backup_id),
         {:ok, manifest} <- archive_manifest(job),
         {:ok, target} <- TargetConfig.module_for(job.target_kind),
         {:ok, ^target, config} <- TargetConfig.resolve() do
      Archive.extract(manifest, target, config, restore_target(job))
    end
  end

  @doc """
  Streams an archive back, checks it, and writes nothing — the deep verification that
  earns the word "verified".

  A `:completed` row only means a write returned; this is the check that the bytes
  still come back as what went in.
  """
  def verify_backup(%BackupJob{} = job) do
    with {:ok, manifest} <- archive_manifest(job),
         {:ok, target} <- TargetConfig.module_for(job.target_kind),
         {:ok, ^target, config} <- TargetConfig.resolve() do
      Archive.extract(manifest, target, config, nil, verify_only: true)
    end
  end

  # Rows written by the restic provider have no manifest, so there is nothing to read
  # them back with. Saying so beats a decode error from deep inside the archive reader.
  defp archive_manifest(%BackupJob{manifest: manifest}) when is_map(manifest) and manifest != %{},
    do: {:ok, manifest}

  defp archive_manifest(%BackupJob{}), do: {:error, :no_archive_manifest}

  # Restores INTO the deployment's own managed directory, not a hardcoded `/data/restore`
  # scratch path that no container ever mounts — restoring there succeeded and put the
  # data nowhere useful, while the UI flashed "restore completed successfully".
  defp restore_target(%BackupJob{deployment: %{app_template: %{slug: slug}}}),
    do: PermanentHome.service_dir(slug)

  defp restore_target(_job), do: PermanentHome.managed_root()
end
