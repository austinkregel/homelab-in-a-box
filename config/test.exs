import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :homelab, Homelab.Repo,
  username: "homelab",
  password: "homelab",
  hostname: System.get_env("DB_HOST", "localhost"),
  port: String.to_integer(System.get_env("DB_PORT", "5433")),
  database: "homelab_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # DBConnection opens the whole pool at Repo start, so this is a per-`mix test`
  # -process cost, not a per-test one. `POOL_SIZE` exists so several concurrent
  # test runs (agents working disjoint file sets, each with its own
  # MIX_TEST_PARTITION) can fit under the server's max_connections without
  # editing this file — see the note in docker-compose.yml.
  pool_size:
    String.to_integer(System.get_env("POOL_SIZE") || to_string(System.schedulers_online() * 2)),
  # Wait out a busy moment instead of dropping the request (default 50ms/1000ms).
  # Load-bearing whenever POOL_SIZE is lowered: without it, an under-provisioned
  # pool surfaces as `DBConnection` queue timeouts that read like test failures.
  queue_target: 5_000,
  queue_interval: 10_000

# In test, the Oban repo uses the SQL sandbox. Oban itself runs in manual testing
# mode (no queues, plugins, or notifier) so jobs only run when a test drains them.
#
# The Oban repo points at its own Postgres server (docker-compose: oban-postgres,
# port 5434), mirroring dev/prod topology. Keep it off the app DB's server when
# that server runs TimescaleDB: `shared_preload_libraries=timescaledb` installs
# planner hooks for *every* database on the server, and the added overhead makes
# this deliberately tiny pool time out under the parallel suite.
#
# A single-Postgres setup (CI) shares one server by pointing DB_OBAN_PORT at it.
config :homelab, Homelab.ObanRepo,
  username: "homelab",
  password: "homelab",
  hostname: System.get_env("DB_OBAN_HOST", System.get_env("DB_HOST", "localhost")),
  port: String.to_integer(System.get_env("DB_OBAN_PORT", "5434")),
  database: "homelab_oban_test#{System.get_env("MIX_TEST_PARTITION")}",
  pool: Ecto.Adapters.SQL.Sandbox,
  # Oban runs in manual testing mode and barely touches its repo, so this pool
  # stays small — when both test repos share one Postgres server (CI), a large
  # pool here would exhaust max_connections. It is not 2, though: every ConnCase
  # test checks out a sandbox owner here, so a 2-connection pool queue-times-out
  # under the parallel suite whenever the machine is loaded.
  pool_size: 6,
  # Wait out a busy moment instead of dropping the request (default 50ms/1000ms).
  queue_target: 500,
  queue_interval: 5_000

config :homelab, Oban, testing: :manual

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :homelab, HomelabWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "au2uxB3bjAlvrzebp8Zth7T3k6UoMyViTcIl9vvnmsP4EIyfXsqJm9cK7Dz4oMOM",
  server: false

# In test we don't send emails
config :homelab, Homelab.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Use mock implementations for all behaviours in tests
config :homelab,
  orchestrator: Homelab.Mocks.Orchestrator,
  identity_broker: Homelab.Mocks.IdentityBroker,
  gateway: Homelab.Mocks.Gateway,
  backup_provider: Homelab.Mocks.BackupProvider,
  public_dns_provider: Homelab.Mocks.DnsProvider,
  internal_dns_provider: Homelab.Mocks.DnsProvider,
  registrar: Homelab.Mocks.RegistrarProvider,
  # Default to an unreachable-daemon stub so incidental Docker callers behave as
  # they did with no daemon. Docker-focused tests opt in per process with
  # `Process.put(:docker_client, Homelab.Mocks.DockerClient)`.
  docker_client: Homelab.Docker.UnavailableClient,
  # Never open a real TLS connection from a test that merely mounts a page.
  tls_probe: Homelab.Networking.TlsProbeStub,
  # Nor a real HTTPS request: `verify_public_url` is planned on every routed release, and
  # the factory's domains are made-up names.
  url_probe: Homelab.Networking.UrlProbeStub,
  # The URL check polls. Tests that stage an unreachable URL are asserting the timeout
  # path, and must not spend the production 90s doing it.
  verify_url_timeout_ms: 50,
  verify_url_interval_ms: 10,
  start_services: false,
  registries: [Homelab.Registries.DockerHub],
  # In-process copy (no helper container) so migration steps run against temp dirs.
  migrate_copy_engine: Homelab.Deployments.Migrate.LocalCopyEngine

# Point the Workbench workspace at an isolated tmp dir per test partition so
# tests never touch a real user's scratch space.
config :homelab, :workbench,
  root:
    Path.join(
      System.tmp_dir!(),
      "homelab-workbench-test#{System.get_env("MIX_TEST_PARTITION")}"
    ),
  quota_bytes: 1_073_741_824,
  ttl_hours: 24

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
