# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :homelab,
  ecto_repos: [Homelab.Repo, Homelab.ObanRepo],
  generators: [timestamp_type: :utc_datetime],
  base_domain: "homelab.local",
  # NOTE: :orchestrator is deliberately NOT set here. `Config.active_driver/2` reads
  # the application env BEFORE Settings, so pinning it would override the operator's
  # choice in Settings → Orchestrator and make that control a no-op — leaving no way
  # off Swarm. The selection lives in Settings; `Bootstrap.backfill_orchestrator/0`
  # records one on first boot. Tests still pin it (config/test.exs) to inject a mock.
  docker_client: Homelab.Docker.ReqClient,
  identity_broker: Homelab.IdentityBrokers.GenericOidc,
  gateway: Homelab.Gateways.Traefik,
  backup_provider: Homelab.BackupProviders.Restic

# Configure the endpoint
config :homelab, HomelabWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HomelabWeb.ErrorHTML, json: HomelabWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Homelab.PubSub,
  live_view: [signing_salt: "fyhX1vsF"]

# Configure Oban (durable, ordered deployment releases).
# Runs against its OWN repo/Postgres instance (Homelab.ObanRepo) to keep job
# churn off the main DB. Kept deliberately light: one queue, the process-group
# notifier (no LISTEN/NOTIFY chatter), prune old jobs, and Lifeline to rescue
# jobs that were executing when a node crashed (crash-resume).
config :homelab, Oban,
  repo: Homelab.ObanRepo,
  notifier: Oban.Notifiers.PG,
  queues: [releases: 4],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 60 * 60 * 24 * 7},
    {Oban.Plugins.Lifeline, rescue_after: :timer.minutes(30)}
  ]

# Maps release-step types to their handler module for the ReleaseRunner saga.
# Unlisted types fall back to the Noop handler (the saga engine still runs).
config :homelab, :release_step_handlers, %{
  # Greenfield deploy steps.
  provision_credentials: Homelab.Deployments.ReleaseSteps.ProvisionCredentials,
  dependency_container: Homelab.Deployments.ReleaseSteps.DeployContainer,
  app_container: Homelab.Deployments.ReleaseSteps.DeployContainer,
  await_health: Homelab.Deployments.ReleaseSteps.AwaitHealth,
  publish_ingress: Homelab.Deployments.ReleaseSteps.PublishIngress,
  # Adoption steps.
  backup_verify: Homelab.Deployments.ReleaseSteps.BackupVerify,
  quiesce_old: Homelab.Deployments.ReleaseSteps.QuiesceOld,
  migrate_volume: Homelab.Deployments.ReleaseSteps.MigrateCopy,
  resume_old: Homelab.Deployments.ReleaseSteps.ResumeOld,
  adopt_credentials: Homelab.Deployments.ReleaseSteps.AdoptCredentials,
  adopt_volume: Homelab.Deployments.ReleaseSteps.AdoptVolume,
  adopt_container: Homelab.Deployments.ReleaseSteps.AdoptContainer,
  verify_integrity: Homelab.Deployments.ReleaseSteps.VerifyIntegrity
}

# Real migrations copy through a throwaway helper container so uid:gid is
# preserved and the containerized plane can reach both paths. Tests override
# this with the in-process LocalCopyEngine (see config/test.exs).
config :homelab, :migrate_copy_engine, Homelab.Deployments.Migrate.ContainerCopyEngine

# Workbench scratch workspace (disk-backed, no DB). `root` holds per-user
# upload dirs joined into build contexts; `quota_bytes` caps each; the janitor
# purges dirs untouched for `ttl_hours`.
config :homelab, :workbench,
  root: Path.join(System.tmp_dir!(), "homelab-workbench"),
  quota_bytes: 1_073_741_824,
  ttl_hours: 24

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :homelab, Homelab.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  homelab: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  homelab: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
