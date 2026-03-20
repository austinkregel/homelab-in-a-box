defmodule HomelabWeb.Api.V1.HealthController do
  use HomelabWeb, :controller

  def index(conn, _params) do
    health = %{
      status: "ok",
      version: Application.spec(:homelab, :vsn) |> to_string(),
      services: %{
        database: check_database(),
        docker_event_listener: check_service(Homelab.Services.DockerEventListener),
        backup_scheduler: check_service(Homelab.Services.BackupScheduler),
        cert_manager: check_service(Homelab.Services.CertManager)
      }
    }

    conn
    |> put_status(if health.services.database == "ok", do: 200, else: 503)
    |> json(health)
  end

  defp check_database do
    case Ecto.Adapters.SQL.query(Homelab.Repo, "SELECT 1") do
      {:ok, _} -> "ok"
      {:error, _} -> "unavailable"
    end
  end

  defp check_service(module) do
    case GenServer.whereis(module) do
      nil -> "not_running"
      pid when is_pid(pid) -> "running"
    end
  end
end
