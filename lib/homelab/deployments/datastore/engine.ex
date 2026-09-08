defmodule Homelab.Deployments.Datastore.Engine do
  @moduledoc """
  The per-distribution knowledge needed to make a declared database EXIST.

  ## Why this is a behaviour and not a `case`

  Creating a database is trivial in every engine and spelled differently in each, so
  the temptation is a `cond` on the image name with a little SQL inlined at each call
  site. That is how a codebase ends up with the same half-correct `CREATE DATABASE`
  in four places, three of which forget that Postgres has no `IF NOT EXISTS` for
  databases.

  So the engine-specific knowledge is confined to one small module per distribution,
  implementing this behaviour, and NOTHING else in the codebase writes SQL. Adding
  MariaDB-flavoured Percona, or CockroachDB, or MSSQL, is a new module and a line in
  `@engines` — not a new branch in a release step.

  ## Why it runs every release, not on first init

  Both major engines only honour their `POSTGRES_DB` / `MARIADB_DATABASE` env on
  FIRST init, when the data directory is empty. A volume that already holds data makes
  the entrypoint skip initialization entirely and ignore the env, silently — the
  `Skipping initialization` line in the log is the whole of the warning you get. The
  same is true of `/docker-entrypoint-initdb.d`: it is first-init only.

  That is the trap this exists to close. An operator who adds a sixth database to a
  running stack has no way to make first-init happen again short of destroying the
  volume, so today they open an SQL client — and a deployment that needs a human with
  `psql` on their laptop is a deployment that stalls. Reconciling on every release
  means a database added to the declaration appears on the next deploy, and one that
  already exists costs an existence check.

  Non-destructive by construction: engines create what is absent and never drop,
  rename, or empty anything. See `c:ensure_database_sql/1`.
  """

  alias Homelab.Deployments.Datastore.Engine

  @typedoc "A module implementing this behaviour."
  @type t :: module()

  @doc "The port the engine listens on when nothing overrides it."
  @callback default_port() :: pos_integer()

  @doc "The administrative user to connect as, read from the datastore's own env."
  @callback admin_user(env :: map()) :: String.t() | nil

  @doc "The administrative password, read from the datastore's own env."
  @callback admin_password(env :: map()) :: String.t() | nil

  @doc """
  The env var the engine's CLI reads a password from, so the credential never
  appears in argv — `/proc/<pid>/cmdline` is world-readable inside the container.
  """
  @callback password_env() :: String.t()

  @doc """
  Idempotent statements that leave `database` existing. MUST NOT drop or modify a
  database that is already there: this runs on every release, against live data.
  """
  @callback ensure_database_sql(database :: String.t()) :: String.t()

  @doc """
  The shell script that pipes `$DB_SQL` into the engine's client, retrying the
  connect briefly — a datastore can report healthy a moment before it accepts TCP.
  """
  @callback script() :: String.t()

  # Matched longest-prefix-first against the image's final path segment, so
  # `timescale/timescaledb` resolves to Postgres rather than falling through.
  @engines [
    {"timescaledb", Engine.Postgres},
    {"postgis", Engine.Postgres},
    {"postgres", Engine.Postgres},
    {"mariadb", Engine.MySQL},
    {"percona", Engine.MySQL},
    {"mysql", Engine.MySQL}
  ]

  # Identifiers are interpolated into SQL, so they are allow-listed rather than
  # escaped. Hyphens are permitted because real apps ask for them — Sonarr's
  # `sonarr-main`/`sonarr-log` pair is the reason this is not `[A-Za-z0-9_]+` — but a
  # leading hyphen is not, and neither is anything that could close a quote.
  @identifier ~r/^[A-Za-z0-9_][A-Za-z0-9_-]*$/

  @doc """
  Resolves the engine module from an image reference.

  Returns `{:error, {:unsupported_engine, image}}` rather than a silent no-op: a
  datastore homelab cannot drive is something the operator needs told, not something
  to quietly skip.
  """
  @spec for_image(String.t()) :: {:ok, t()} | {:error, term()}
  def for_image(image) when is_binary(image) do
    name = image |> String.split("/") |> List.last() |> String.downcase()

    case Enum.find(@engines, fn {prefix, _mod} -> String.starts_with?(name, prefix) end) do
      {_prefix, module} -> {:ok, module}
      nil -> {:error, {:unsupported_engine, image}}
    end
  end

  def for_image(_image), do: {:error, {:unsupported_engine, nil}}

  @doc "True when `image` names an engine this module can drive."
  @spec supported_image?(String.t()) :: boolean()
  def supported_image?(image), do: match?({:ok, _}, for_image(image))

  @doc """
  Checks a database name against the allow-list. Returns the name so it can be
  used in a `with` chain.
  """
  @spec validate_identifier(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate_identifier(name) when is_binary(name) do
    if Regex.match?(@identifier, name),
      do: {:ok, name},
      else: {:error, {:invalid_database_name, name}}
  end

  def validate_identifier(name), do: {:error, {:invalid_database_name, name}}
end
