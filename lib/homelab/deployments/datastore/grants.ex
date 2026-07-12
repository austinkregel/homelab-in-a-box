defmodule Homelab.Deployments.Datastore.Grants do
  @moduledoc """
  Reconciles a datastore's ACTUAL users/grants with the credentials homelab holds.

  ## Why this exists

  aut.hair served a Laravel 500 — healthy app, healthy database, `Access denied for
  user 'authair'` — because of two independent faults that look identical from the
  outside:

    1. **The datastore never applied its env.** MariaDB/MySQL only honour
       `MARIADB_USER` / `MARIADB_PASSWORD` on first init, when the data directory is
       empty. A volume that already holds data (adopted from an existing stack, or
       surviving a redeploy) makes the entrypoint skip init entirely and keep the
       grants it already had. The env is ignored, silently.

    2. **The app and the datastore hold different secrets.** `ProvisionCredentials`
       shares a value by KEY NAME, and the two sides spell the same concept
       differently — Laravel reads `DB_PASSWORD`, MariaDB reads `MARIADB_PASSWORD`.
       Different key, different generated value. So even a datastore that *did*
       apply its env would be expecting a password the app never sends.

  Either way the credential is *believed* rather than *true*. This module makes it
  true, by granting exactly what the APP is configured to send (see
  `credentials_from_env/3` — reconciling against the datastore's own env instead is
  fault 2, and it is the trap that kept aut.hair down after its database had
  supposedly been repaired).

  This module closes that loop by making the database true rather than assumed. It
  is deliberately **non-destructive**: it creates the user/database if absent and
  resets the password to the one homelab already hands out. It never drops a user,
  a database, or a row. Repairing must never be able to cost you data — the
  alternative ("regenerate the volume so init runs again") destroys the database,
  which for an identity provider means every user and OAuth client.

  Idempotent by construction, so it is safe to run on every release and safe to
  expose as a Repair button.
  """

  @type engine :: :mysql

  @type params :: %{
          engine: engine(),
          host: String.t(),
          port: pos_integer(),
          admin_user: String.t(),
          admin_password: String.t(),
          app_user: String.t(),
          app_password: String.t(),
          database: String.t()
        }

  @callback reconcile(params()) :: {:ok, map()} | {:error, term()}

  # Identifiers are interpolated into SQL, so they are allow-listed rather than
  # escaped. A datastore user/database name outside this set is a bug or an attack;
  # either way it must not reach the server.
  @identifier ~r/^[A-Za-z0-9_]+$/

  @doc """
  Builds the idempotent SQL that makes `app_user` able to reach `database` with
  `app_password`. Returns `{:error, {:invalid_identifier, …}}` rather than emitting
  SQL it cannot vouch for.
  """
  @spec build_sql(params()) :: {:ok, String.t()} | {:error, term()}
  def build_sql(%{engine: :mysql} = params) do
    with :ok <- validate_identifier(params.app_user, :app_user),
         :ok <- validate_identifier(params.database, :database) do
      user = params.app_user
      db = params.database
      pw = escape_literal(params.app_password)

      # CREATE ... IF NOT EXISTS then ALTER: the user may exist with a stale password
      # (the whole point), so creating alone is not enough. GRANT is re-issued because
      # an adopted user may hold grants on a different schema.
      sql = """
      CREATE DATABASE IF NOT EXISTS `#{db}`;
      CREATE USER IF NOT EXISTS `#{user}`@`%` IDENTIFIED BY '#{pw}';
      ALTER USER `#{user}`@`%` IDENTIFIED BY '#{pw}';
      GRANT ALL PRIVILEGES ON `#{db}`.* TO `#{user}`@`%`;
      FLUSH PRIVILEGES;
      """

      {:ok, String.trim(sql)}
    end
  end

  def build_sql(%{engine: engine}), do: {:error, {:unsupported_engine, engine}}

  @doc """
  Infers the datastore engine from an image reference. Only MySQL/MariaDB is
  supported today; anything else is an explicit error, never a silent no-op.
  """
  @spec engine_for_image(String.t()) :: {:ok, engine()} | {:error, term()}
  def engine_for_image(image) when is_binary(image) do
    name = image |> String.split("/") |> List.last() |> String.downcase()

    cond do
      String.starts_with?(name, "mariadb") -> {:ok, :mysql}
      String.starts_with?(name, "mysql") -> {:ok, :mysql}
      String.starts_with?(name, "percona") -> {:ok, :mysql}
      true -> {:error, {:unsupported_engine, image}}
    end
  end

  # The credentials the APP is configured with. Read from the app's OWN env, because
  # that is what it will actually send on the wire.
  #
  # This is the subtle one. `ProvisionCredentials` shares a secret by KEY NAME, and
  # the two sides of a pair use different names: Laravel reads `DB_PASSWORD`, MariaDB
  # reads `MARIADB_PASSWORD`. Same concept, different key -- so they are two
  # independent secrets holding two different values. Reconciling the database
  # against its own `MARIADB_PASSWORD` therefore grants a password the app never
  # sends, and the app still gets `Access denied`. aut.hair failed exactly this way,
  # twice.
  #
  # Env var names vary per app (`DB_*` for Laravel, `MYSQL_*` for Nextcloud), so the
  # keys can be declared explicitly and fall back to the common spellings.
  @app_user_keys ~w(DB_USERNAME DB_USER MYSQL_USER MARIADB_USER)
  @app_password_keys ~w(DB_PASSWORD MYSQL_PASSWORD MARIADB_PASSWORD)
  @app_database_keys ~w(DB_DATABASE DB_NAME MYSQL_DATABASE MARIADB_DATABASE)
  @admin_password_keys ~w(MARIADB_ROOT_PASSWORD MYSQL_ROOT_PASSWORD)

  @doc """
  Resolves what to grant from the APP's env, and who to grant it as from the
  DATASTORE's env (the admin/root credential).

  `keys` may name the env vars explicitly (`%{"user" => "DB_USERNAME", …}`);
  anything absent falls back to the conventional spellings.
  """
  @spec credentials_from_env(map(), map(), map()) :: {:ok, map()} | {:error, term()}
  def credentials_from_env(app_env, datastore_env, keys \\ %{}) do
    app_user = pick(app_env, keys["user"], @app_user_keys)
    app_password = pick(app_env, keys["password"], @app_password_keys)
    database = pick(app_env, keys["database"], @app_database_keys)
    admin_password = pick(datastore_env, keys["admin_password"], @admin_password_keys)

    missing =
      [
        {"app user", app_user},
        {"app password", app_password},
        {"database", database},
        {"datastore root password", admin_password}
      ]
      |> Enum.filter(fn {_label, value} -> value in [nil, ""] end)
      |> Enum.map(&elem(&1, 0))

    if missing == [] do
      {:ok,
       %{
         admin_user: "root",
         admin_password: admin_password,
         app_user: app_user,
         app_password: app_password,
         database: database
       }}
    else
      {:error, {:missing_datastore_env, missing}}
    end
  end

  defp pick(env, declared, fallbacks) when is_binary(declared),
    do: env[declared] || pick(env, nil, fallbacks)

  defp pick(env, _declared, fallbacks) do
    Enum.find_value(fallbacks, fn key ->
      case env[key] do
        value when value not in [nil, ""] -> value
        _ -> nil
      end
    end)
  end

  defp validate_identifier(value, field) when is_binary(value) do
    if Regex.match?(@identifier, value),
      do: :ok,
      else: {:error, {:invalid_identifier, field, value}}
  end

  defp validate_identifier(value, field), do: {:error, {:invalid_identifier, field, value}}

  # MySQL string literal: backslash first, then the quote, or the escapes escape
  # each other.
  defp escape_literal(password) when is_binary(password) do
    password
    |> String.replace("\\", "\\\\")
    |> String.replace("'", "\\'")
  end
end
