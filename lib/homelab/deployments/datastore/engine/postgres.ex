defmodule Homelab.Deployments.Datastore.Engine.Postgres do
  @moduledoc """
  Postgres (and its derivatives — TimescaleDB, PostGIS).

  Two facts shape everything here:

    * There is no `CREATE DATABASE IF NOT EXISTS`. The portable idiom is to SELECT
      the statement text guarded by a `NOT EXISTS` on `pg_database` and let psql's
      `\\gexec` execute whatever rows come back — zero rows when the database is
      already there, so a re-run is a catalog lookup and nothing else.

    * `CREATE DATABASE` cannot run inside a transaction block, which rules out
      wrapping the batch for atomicity. Each statement therefore stands alone, and
      `ON_ERROR_STOP=1` makes the first genuine failure end the run instead of
      letting five more scroll past.

  Connects to the `postgres` maintenance database, which always exists — connecting
  to one of the databases being created is a chicken-and-egg the first time.
  """

  @behaviour Homelab.Deployments.Datastore.Engine

  @impl true
  def default_port, do: 5432

  # POSTGRES_USER names the superuser the image creates on first init; the official
  # image defaults it to "postgres" when unset.
  @impl true
  def admin_user(env), do: presence(env["POSTGRES_USER"]) || "postgres"

  @impl true
  def admin_password(env), do: presence(env["POSTGRES_PASSWORD"])

  @impl true
  def password_env, do: "PGPASSWORD"

  # Single-quoted literals here are the database NAME as data (the pg_database
  # lookup), not an identifier -- the identifier is the double-quoted copy inside the
  # statement text. `Engine.validate_identifier/1` has already refused anything that
  # could close either quote.
  @impl true
  def ensure_database_sql(database) do
    """
    SELECT 'CREATE DATABASE "#{database}"'
     WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '#{database}')
    \\gexec
    """
  end

  @impl true
  def script do
    """
    set -eu
    i=0
    while [ $i -lt 15 ]; do
      if printf '%s' "$DB_SQL" | psql -v ON_ERROR_STOP=1 \
           -h "$DB_HOST" -p "$DB_PORT" -U "$DB_ADMIN" -d postgres; then
        exit 0
      fi
      i=$((i+1))
      sleep 2
    done
    exit 1
    """
  end

  defp presence(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp presence(_value), do: nil
end
