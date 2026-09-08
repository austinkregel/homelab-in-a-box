defmodule Homelab.Deployments.Datastore.Engine.MySQL do
  @moduledoc """
  MySQL and its wire-compatible relatives (MariaDB, Percona).

  Simpler than Postgres: `CREATE DATABASE IF NOT EXISTS` is native, so the idempotent
  form is the obvious one and no guard query is needed.

  The client binary is resolved at runtime (`mariadb` on modern MariaDB images, `mysql`
  everywhere else) because the container runs the datastore's OWN image, and which of
  the two names ships depends on the distribution and its version.
  """

  @behaviour Homelab.Deployments.Datastore.Engine

  @impl true
  def default_port, do: 3306

  # The root account is what the image's first init establishes a password for; there
  # is no per-image override of the NAME the way Postgres has POSTGRES_USER.
  @impl true
  def admin_user(_env), do: "root"

  @impl true
  def admin_password(env) do
    presence(env["MARIADB_ROOT_PASSWORD"]) || presence(env["MYSQL_ROOT_PASSWORD"])
  end

  @impl true
  def password_env, do: "MYSQL_PWD"

  @impl true
  def ensure_database_sql(database) do
    "CREATE DATABASE IF NOT EXISTS `#{database}`;\n"
  end

  @impl true
  def script do
    """
    set -eu
    client=$(command -v mariadb || command -v mysql)
    i=0
    while [ $i -lt 15 ]; do
      if printf '%s' "$DB_SQL" | "$client" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ADMIN"; then
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
