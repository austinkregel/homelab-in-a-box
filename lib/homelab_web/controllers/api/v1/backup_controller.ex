defmodule HomelabWeb.Api.V1.BackupController do
  use HomelabWeb, :controller

  alias Homelab.Backups

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, params) do
    jobs =
      case params do
        %{"deployment_id" => deployment_id} ->
          Backups.list_backup_jobs_for_deployment(deployment_id)

        _ ->
          Backups.list_backup_jobs()
      end

    render(conn, :index, backup_jobs: jobs)
  end

  def show(conn, %{"id" => id}) do
    with {:ok, job} <- Backups.get_backup_job(id) do
      render(conn, :show, backup_job: job)
    end
  end

  def create(conn, %{"backup" => backup_params}) do
    with {:ok, job} <- Backups.create_backup_job(backup_params) do
      conn
      |> put_status(:created)
      |> render(:show, backup_job: job)
    end
  end

  def restore(conn, %{"id" => id}) do
    backup_provider = Homelab.Config.backup_provider()

    with {:ok, job} <- Backups.get_backup_job(id),
         :ok <- backup_provider.restore(job.snapshot_id, "/data/restore") do
      render(conn, :show, backup_job: job)
    end
  end
end
