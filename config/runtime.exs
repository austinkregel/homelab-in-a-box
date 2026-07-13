import Config

# Load .env file if it exists. Existing system env vars take precedence.
if File.exists?(".env") do
  Dotenvy.source!([".env", System.get_env()])
end

if System.get_env("PHX_SERVER") do
  config :homelab, HomelabWeb.Endpoint, server: true
end

config :homelab, HomelabWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

bootstrap? = System.get_env("BOOTSTRAP") in ~w(true 1)
config :homelab, bootstrap: bootstrap?

# Storage roots for the adoption/migration flow. `adoption_root` delimits which
# of your existing bind mounts are in-scope for discovery; `managed_root` is the
# local disk where plane-managed volumes physically live. Both default to sane
# values in their modules and can also be overridden at runtime from
# Settings -> Infrastructure (which wins over these). Set them to match your host.
if adoption_root = System.get_env("HOMELAB_ADOPTION_ROOT") do
  config :homelab, :adoption_root, adoption_root
end

if managed_root = System.get_env("HOMELAB_MANAGED_ROOT") do
  config :homelab, :managed_root, managed_root
end

# Where the adoption backup gate writes its verified copies. It defaulted to the
# system temp dir — INSIDE this container — so the one restorable copy standing
# between an adoption and the operator's data disappeared with the container. Point
# it at a mounted path that outlives us.
if backup_root = System.get_env("HOMELAB_BACKUP_ROOT") do
  config :homelab, :backup_root, backup_root
end

# The public base domain (e.g. homelab.kregel.dev). Config.base_domain/0 reads
# this app-env; without it the value was permanently the "homelab.local" default,
# regardless of HOMELAB_BASE_DOMAIN — which then flowed into deployment domains,
# the registry hostnames, and the Traefik self-ingress route + wildcard cert.
if base_domain = System.get_env("HOMELAB_BASE_DOMAIN") do
  config :homelab, :base_domain, base_domain
end

# Emergency, non-OIDC admin login (see Homelab.Auth.BreakGlass). The token is NOT
# an env var: it lives in a file, and a successful login CONSUMES (deletes) it so
# it can't be reused. The route 404s until the file holds a >= 24-char token.
# Arm it by writing that file (defaults into the homelab-iab-secrets volume), e.g.
#   docker exec homelab bin/homelab rpc 'IO.puts(Homelab.Auth.BreakGlass.arm!())'
config :homelab, :breakglass,
  token_file:
    System.get_env(
      "HOMELAB_BREAKGLASS_TOKEN_FILE",
      Path.join(System.get_env("HOMELAB_SECRETS_DIR", "/run/secrets"), "breakglass_token")
    ),
  user: System.get_env("HOMELAB_BREAKGLASS_USER", "breakglass")

if bootstrap? do
  config :homelab, :docker_socket, System.get_env("DOCKER_SOCKET", "/var/run/docker.sock")

  config :homelab, HomelabWeb.Endpoint,
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT", "4000"))]
end

if config_env() == :prod do
  if !bootstrap? do
    database_url =
      System.get_env("DATABASE_URL") ||
        raise """
        environment variable DATABASE_URL is missing.
        For example: ecto://USER:PASS@HOST/DATABASE
        """

    maybe_ipv6 = if System.get_env("ECTO_IPV6") in ~w(true 1), do: [:inet6], else: []

    config :homelab, Homelab.Repo,
      url: database_url,
      pool_size: String.to_integer(System.get_env("POOL_SIZE") || "10"),
      socket_options: maybe_ipv6

    # Oban uses its OWN database (separate instance recommended) to keep its job
    # churn off the main app DB. Supply OBAN_DATABASE_URL when not bootstrapping.
    oban_database_url =
      System.get_env("OBAN_DATABASE_URL") ||
        raise """
        environment variable OBAN_DATABASE_URL is missing.
        Oban runs on a dedicated database to isolate its load from the app DB.
        For example: ecto://USER:PASS@HOST/homelab_oban
        """

    config :homelab, Homelab.ObanRepo,
      url: oban_database_url,
      pool_size: String.to_integer(System.get_env("OBAN_POOL_SIZE") || "6"),
      socket_options: maybe_ipv6
  end

  # Secrets are persisted to a durable directory (mount the `homelab-iab-secrets`
  # volume at HOMELAB_SECRETS_DIR) so they survive container restarts. An
  # explicit env var always wins — that is how you supply a Docker/Swarm secret.
  #
  # This matters because secret_key_base is also the key that encrypts every
  # credential stored in the database (see Homelab.Settings). If it is
  # regenerated on each boot, all encrypted settings become undecryptable.
  secrets_dir = System.get_env("HOMELAB_SECRETS_DIR", "/run/secrets")

  fetch_or_create_secret = fn name, generate ->
    path = Path.join(secrets_dir, name)

    case File.read(path) do
      {:ok, contents} ->
        case String.trim(contents) do
          "" -> generate.()
          value -> value
        end

      {:error, _} ->
        value = generate.()
        _ = File.mkdir_p(secrets_dir)

        case File.write(path, value) do
          :ok ->
            :ok

          {:error, reason} ->
            IO.warn(
              "Could not persist #{name} to #{path} (#{inspect(reason)}); using an " <>
                "ephemeral value. Mount the homelab-iab-secrets volume to persist secrets."
            )
        end

        value
    end
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      fetch_or_create_secret.("secret_key_base", fn ->
        Base.encode64(:crypto.strong_rand_bytes(48))
      end)

  host =
    System.get_env("PHX_HOST") ||
      raise """
      environment variable PHX_HOST is missing.
      Set it to the public hostname users reach this app at, e.g. homelab.example.com
      """

  scheme = System.get_env("PHX_SCHEME", "https")
  url_port = String.to_integer(System.get_env("PHX_PORT", "443"))

  config :homelab, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :homelab, HomelabWeb.Endpoint,
    url: [host: host, port: url_port, scheme: scheme],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # Error tracking. Inert unless SENTRY_DSN is set — point it at the Sentry
  # instance in your homelab stack to start receiving crash reports.
  config :sentry,
    dsn: System.get_env("SENTRY_DSN"),
    environment_name: System.get_env("SENTRY_ENV", "production"),
    release: System.get_env("RELEASE_VSN")

  # Structured JSON logs in production for easier aggregation/searching.
  config :logger, :default_handler,
    formatter: LoggerJSON.Formatters.Basic.new(metadata: [:request_id])
end
