defmodule Homelab.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    maybe_attach_sentry_logger()

    case Homelab.Bootstrap.ensure_infrastructure() do
      :ok -> :ok
      {:error, reason} -> raise "Bootstrap failed: #{inspect(reason)}"
    end

    children = [
      HomelabWeb.Telemetry,
      Homelab.Repo,
      # Oban's repo points at a dedicated Postgres instance; start it before the
      # MigrationRunner so its job table can be migrated alongside the app DB.
      Homelab.ObanRepo,
      {DNSCluster, query: Application.get_env(:homelab, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Homelab.PubSub},
      {Task.Supervisor, name: Homelab.Workers.TaskSupervisor, max_children: 10},
      # Separate from the workers' pool: a TLS probe is per-open-page UI work, and
      # borrowing the bounded worker supervisor would let a handful of open deployment
      # pages starve real background jobs.
      {Task.Supervisor, name: Homelab.TlsProbeSupervisor},
      Homelab.Services.ActivityLog,
      Homelab.MigrationRunner,
      # Oban starts after migrations so its job table exists.
      {Oban, Application.fetch_env!(:homelab, Oban)},
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

  # Routes crash/error logs to Sentry, but only when a DSN is configured so
  # dev and test stay quiet. Safe to call once at startup.
  defp maybe_attach_sentry_logger do
    if Application.get_env(:sentry, :dsn) do
      :logger.add_handler(:homelab_sentry_handler, Sentry.LoggerHandler, %{
        config: %{metadata: [:file, :line], level: :error}
      })
    end
  end

  defp services_children do
    if Application.get_env(:homelab, :start_services, true) do
      [
        # Stands up Traefik on boot (before deploys need it), then keeps it up.
        Homelab.Services.GatewayProvisioner,
        Homelab.Services.Reconciler,
        Homelab.Services.DockerEventListener,
        Homelab.Services.BackupScheduler,
        Homelab.Services.CertManager,
        Homelab.Services.CatalogSyncer,
        Homelab.Services.MetricsCollector,
        Homelab.Services.RegistrarSyncer,
        Homelab.Services.WorkbenchJanitor
      ]
    else
      []
    end
  end
end
