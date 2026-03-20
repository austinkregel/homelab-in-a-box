defmodule Homelab.Catalog.Enrichers.DatabaseDetector do
  @moduledoc """
  Detects database-related environment variables and suggests companion
  database containers or auto-generated secrets when they're missing.
  """

  @db_profiles %{
    mysql: %{
      label: "MySQL",
      image: "lscr.io/linuxserver/mariadb:latest",
      icon: "hero-circle-stack",
      env_patterns:
        ~w(MYSQL_ MARIADB_ DB_HOST DB_PORT DB_DATABASE DB_USERNAME DB_PASSWORD DB_CONNECTION),
      host_keys: ~w(DB_HOST MYSQL_HOST MARIADB_HOST),
      port_keys: ~w(DB_PORT MYSQL_PORT MARIADB_PORT),
      user_keys: ~w(DB_USERNAME DB_USER MYSQL_USER MARIADB_USER),
      pass_keys:
        ~w(DB_PASSWORD MYSQL_PASSWORD MYSQL_ROOT_PASSWORD MARIADB_PASSWORD MARIADB_ROOT_PASSWORD),
      name_keys: ~w(DB_DATABASE MYSQL_DATABASE MARIADB_DATABASE),
      default_port: "3306",
      companion_env: %{
        "MYSQL_ROOT_PASSWORD" => :secret,
        "MYSQL_DATABASE" => "app",
        "MYSQL_USER" => "app",
        "MYSQL_PASSWORD" => :secret
      },
      companion_ports: [
        %{
          "internal" => "3306",
          "external" => "3306",
          "role" => "database",
          "description" => "MySQL"
        }
      ],
      companion_volumes: [%{"container_path" => "/config", "description" => "Database data"}]
    },
    postgres: %{
      label: "PostgreSQL",
      image: "postgres:16-alpine",
      icon: "hero-circle-stack",
      env_patterns: ~w(POSTGRES_ PG_ PGHOST PGPORT PGUSER PGPASSWORD PGDATABASE),
      host_keys: ~w(DB_HOST POSTGRES_HOST PGHOST),
      port_keys: ~w(DB_PORT POSTGRES_PORT PGPORT),
      user_keys: ~w(DB_USERNAME DB_USER POSTGRES_USER PGUSER),
      pass_keys: ~w(DB_PASSWORD POSTGRES_PASSWORD PGPASSWORD),
      name_keys: ~w(DB_DATABASE POSTGRES_DB PGDATABASE),
      default_port: "5432",
      companion_env: %{
        "POSTGRES_PASSWORD" => :secret,
        "POSTGRES_DB" => "app",
        "POSTGRES_USER" => "app"
      },
      companion_ports: [
        %{
          "internal" => "5432",
          "external" => "5432",
          "role" => "database",
          "description" => "PostgreSQL"
        }
      ],
      companion_volumes: [
        %{"container_path" => "/var/lib/postgresql/data", "description" => "Database data"}
      ]
    },
    redis: %{
      label: "Redis",
      image: "redis:7-alpine",
      icon: "hero-bolt",
      env_patterns: ~w(REDIS_HOST REDIS_PORT REDIS_PASSWORD REDIS_URL CACHE_DRIVER),
      host_keys: ~w(REDIS_HOST),
      port_keys: ~w(REDIS_PORT),
      user_keys: [],
      pass_keys: ~w(REDIS_PASSWORD),
      name_keys: [],
      default_port: "6379",
      companion_env: %{},
      companion_ports: [
        %{
          "internal" => "6379",
          "external" => "6379",
          "role" => "database",
          "description" => "Redis"
        }
      ],
      companion_volumes: [%{"container_path" => "/data", "description" => "Redis data"}]
    },
    mongodb: %{
      label: "MongoDB",
      image: "mongo:7",
      icon: "hero-circle-stack",
      env_patterns: ~w(MONGO_ MONGODB_),
      host_keys: ~w(MONGO_HOST MONGODB_HOST),
      port_keys: ~w(MONGO_PORT MONGODB_PORT),
      user_keys: ~w(MONGO_USER MONGODB_USER MONGO_INITDB_ROOT_USERNAME),
      pass_keys: ~w(MONGO_PASSWORD MONGODB_PASSWORD MONGO_INITDB_ROOT_PASSWORD),
      name_keys: ~w(MONGO_DATABASE MONGODB_DATABASE),
      default_port: "27017",
      companion_env: %{
        "MONGO_INITDB_ROOT_USERNAME" => "app",
        "MONGO_INITDB_ROOT_PASSWORD" => :secret
      },
      companion_ports: [
        %{
          "internal" => "27017",
          "external" => "27017",
          "role" => "database",
          "description" => "MongoDB"
        }
      ],
      companion_volumes: [%{"container_path" => "/data/db", "description" => "Database data"}]
    }
  }

  @doc """
  Analyzes a list of env var maps (`%{"key" => ..., "value" => ...}`) and
  returns a list of detected database dependency descriptors.

  Each descriptor contains:
  - `:db_type` — atom like `:mysql`, `:postgres`, `:redis`, `:mongodb`
  - `:label` — human-readable name
  - `:image` — suggested companion container image
  - `:icon` — hero icon name for UI
  - `:matched_keys` — env var keys that triggered the detection
  - `:missing_keys` — env var keys that have no value set
  - `:wiring` — map of parent env key => suggested value when companion is added
  - `:companion_env` — env vars for the companion container itself
  - `:companion_ports` — ports for the companion
  - `:companion_volumes` — volumes for the companion
  """
  def detect(env_vars) when is_list(env_vars) do
    env_map = Map.new(env_vars, fn e -> {e["key"], e["value"]} end)

    @db_profiles
    |> Enum.map(fn {db_type, profile} -> {db_type, profile, match_score(env_map, profile)} end)
    |> Enum.filter(fn {_, _, {score, _keys}} -> score > 0 end)
    |> Enum.sort_by(fn {_, _, {score, _}} -> score end, :desc)
    |> Enum.map(fn {db_type, profile, {_score, matched_keys}} ->
      missing = matched_keys |> Enum.filter(fn k -> blank?(env_map[k]) end)

      %{
        db_type: db_type,
        label: profile.label,
        image: profile.image,
        icon: profile.icon,
        matched_keys: matched_keys,
        missing_keys: missing,
        wiring: build_wiring(db_type, profile, env_map),
        companion_env: resolve_companion_env(profile.companion_env),
        companion_ports: profile.companion_ports,
        companion_volumes: profile.companion_volumes
      }
    end)
  end

  @doc """
  Generates a cryptographically random secret string.
  """
  def generate_secret(length \\ 32) do
    length
    |> :crypto.strong_rand_bytes()
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end

  defp match_score(env_map, profile) do
    keys = Map.keys(env_map)

    matched =
      keys
      |> Enum.filter(fn key ->
        Enum.any?(profile.env_patterns, fn pattern ->
          String.starts_with?(String.upcase(key), pattern)
        end)
      end)

    {length(matched), matched}
  end

  defp build_wiring(db_type, profile, env_map) do
    service_name = Atom.to_string(db_type)

    wiring = %{}

    wiring = wire_keys(wiring, profile.host_keys, env_map, service_name)
    wiring = wire_keys(wiring, profile.port_keys, env_map, profile.default_port)
    wiring = wire_keys(wiring, profile.name_keys, env_map, "app")
    wiring = wire_keys(wiring, profile.user_keys, env_map, "app")
    wire_keys(wiring, profile.pass_keys, env_map, :secret)
  end

  defp wire_keys(wiring, candidate_keys, env_map, value) do
    present_keys = Enum.filter(candidate_keys, fn k -> Map.has_key?(env_map, k) end)

    Enum.reduce(present_keys, wiring, fn key, acc ->
      suggested = if value == :secret, do: generate_secret(24), else: value
      Map.put(acc, key, suggested)
    end)
  end

  defp resolve_companion_env(env_map) do
    Map.new(env_map, fn
      {k, :secret} -> {k, generate_secret(24)}
      {k, v} -> {k, v}
    end)
  end

  defp blank?(nil), do: true
  defp blank?(""), do: true
  defp blank?(_), do: false
end
