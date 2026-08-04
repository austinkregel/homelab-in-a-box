defmodule HomelabWeb.Api.V1.BackupController do
  @moduledoc """
  Backups, addressed inside a tenant.

  Every action takes `tenant_id` from the path and scopes on it, the same shape
  `DeploymentController` already uses. Before that, this controller was routed at the top
  level: `index` fell through to `Backups.list_backup_jobs/0` (every tenant's jobs) and
  `show`/`restore` took a bare id with no scope, so any signed-in user could read every
  tenant's backup history and restore any tenant's snapshot over `/data/restore`.

  Note that tenants are not yet an access boundary — there is no `tenant_id` on `users`
  and no join table, so a caller can still name any tenant. Scoping here removes the
  ambient surface and leaves one place to enforce membership when that model exists.
  """
  use HomelabWeb, :controller

  alias Homelab.Backups
  alias Homelab.Deployments

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, %{"tenant_id" => tenant_id, "deployment_id" => deployment_id}) do
    # The filter has to be re-scoped too, or it is a way back out of the tenant.
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(tenant_id, deployment_id) do
      render(conn, :index, backup_jobs: Backups.list_backup_jobs_for_deployment(deployment.id))
    end
  end

  def index(conn, %{"tenant_id" => tenant_id}) do
    render(conn, :index, backup_jobs: Backups.list_backup_jobs_for_tenant(tenant_id))
  end

  def show(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    with {:ok, job} <- Backups.get_backup_job_for_tenant(tenant_id, id) do
      render(conn, :show, backup_job: job)
    end
  end

  def create(conn, %{"tenant_id" => tenant_id, "backup" => backup_params}) do
    # The deployment id arrives in the body, so the path's tenant means nothing until
    # it is checked against it — otherwise the scope is decoration.
    with {:ok, deployment} <-
           Deployments.get_deployment_for_tenant(tenant_id, backup_params["deployment_id"]),
         {:ok, job} <-
           Backups.create_backup_job(Map.put(backup_params, "deployment_id", deployment.id)) do
      conn
      |> put_status(:created)
      |> render(:show, backup_job: job)
    end
  end

  def restore(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    backup_provider = Homelab.Config.backup_provider()

    with {:ok, job} <- Backups.get_backup_job_for_tenant(tenant_id, id),
         :ok <- backup_provider.restore(job.snapshot_id, "/data/restore") do
      render(conn, :show, backup_job: job)
    end
  end
end
