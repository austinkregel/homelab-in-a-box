defmodule Homelab.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    case Homelab.Bootstrap.ensure_infrastructure() do
      :ok -> :ok
      {:error, reason} -> raise "Bootstrap failed: #{inspect(reason)}"
    end

    children = [
      HomelabWeb.Telemetry,
      Homelab.Repo,
      {DNSCluster, query: Application.get_env(:homelab, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Homelab.PubSub},
      {Task.Supervisor, name: Homelab.Workers.TaskSupervisor, max_children: 10},
      Homelab.Services.ActivityLog,
      Homelab.MigrationRunner,
      %{
        id: Homelab.ServicesSupervisor,
        type: :supervisor,
        start:
          {Supervisor, :start_link,
           [services_children(), [strategy: :one_for_one, name: Homelab.ServicesSupervisor]]}
      },
      HomelabWeb.Endpoint
    ]

    opts = [strategy: :one_for_one, name: Homelab.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def config_change(changed, _new, removed) do
    HomelabWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp services_children do
    if Application.get_env(:homelab, :start_services, true) do
      [
        Homelab.Services.DockerEventListener,
        Homelab.Services.BackupScheduler,
        Homelab.Services.CertManager,
        Homelab.Services.CatalogSyncer,
        Homelab.Services.MetricsCollector,
        Homelab.Services.RegistrarSyncer
      ]
    else
      []
    end
  end
end
