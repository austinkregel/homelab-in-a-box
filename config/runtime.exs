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
  end

  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      Base.encode64(:crypto.strong_rand_bytes(48))

  host = System.get_env("PHX_HOST", "localhost")

  config :homelab, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :homelab, HomelabWeb.Endpoint,
    url: [host: host, port: String.to_integer(System.get_env("PHX_PORT", "4000")), scheme: "http"],
    http: [
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base
end
