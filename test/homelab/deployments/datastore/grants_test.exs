defmodule Homelab.Deployments.Datastore.GrantsTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Datastore.Grants

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        engine: :mysql,
        host: "homelab_identity_authair-db",
        port: 3306,
        admin_user: "root",
        admin_password: "rootpw",
        app_user: "authair",
        app_password: "s3cret",
        database: "authair"
      },
      overrides
    )
  end

  describe "build_sql/1" do
    # The user already EXISTS with a stale password -- that is the entire failure
    # mode. Creating alone would be a no-op, so the password must be reset too.
    test "creates the user and resets the password of an existing one" do
      assert {:ok, sql} = Grants.build_sql(params())

      assert sql =~ "CREATE DATABASE IF NOT EXISTS `authair`"
      assert sql =~ "CREATE USER IF NOT EXISTS `authair`@`%` IDENTIFIED BY 's3cret'"
      assert sql =~ "ALTER USER `authair`@`%` IDENTIFIED BY 's3cret'"
      assert sql =~ "GRANT ALL PRIVILEGES ON `authair`.* TO `authair`@`%`"
      assert sql =~ "FLUSH PRIVILEGES"
    end

    # Repair must never be able to cost data. If a DROP can be emitted, the button
    # is not safe to put next to a production database.
    test "never emits a destructive statement" do
      assert {:ok, sql} = Grants.build_sql(params())

      for destructive <- ~w(DROP DELETE TRUNCATE REVOKE) do
        refute sql =~ destructive, "repair emitted a destructive statement: #{destructive}"
      end
    end

    test "escapes quotes and backslashes in the password" do
      assert {:ok, sql} = Grants.build_sql(params(%{app_password: "a'b\\c"}))
      assert sql =~ "IDENTIFIED BY 'a\\'b\\\\c'"
    end

    # Identifiers are interpolated, not bound, so they are allow-listed. A name that
    # could break out of the backticks must be refused, not escaped-and-hoped.
    test "refuses an identifier that is not a plain name" do
      assert {:error, {:invalid_identifier, :app_user, _}} =
               Grants.build_sql(params(%{app_user: "authair`; DROP DATABASE x; --"}))

      assert {:error, {:invalid_identifier, :database, _}} =
               Grants.build_sql(params(%{database: "auth-hair"}))
    end

    test "an unsupported engine is an explicit error, not a silent no-op" do
      assert {:error, {:unsupported_engine, :postgres}} =
               Grants.build_sql(params(%{engine: :postgres}))
    end
  end

  describe "engine_for_image/1" do
    test "recognizes the MySQL family" do
      assert {:ok, :mysql} = Grants.engine_for_image("mariadb:11")
      assert {:ok, :mysql} = Grants.engine_for_image("mysql:8")
      assert {:ok, :mysql} = Grants.engine_for_image("docker.io/library/mariadb:10.11")
    end

    test "anything else is unsupported rather than assumed" do
      assert {:error, {:unsupported_engine, _}} = Grants.engine_for_image("postgres:16")
      assert {:error, {:unsupported_engine, _}} = Grants.engine_for_image("redis:7-alpine")
    end
  end

  describe "credentials_from_env/3" do
    # THE bug that kept aut.hair down after its database had supposedly been repaired.
    # ProvisionCredentials shares a secret by KEY NAME, and the app and the datastore
    # use different names for the same concept -- so DB_PASSWORD and MARIADB_PASSWORD
    # are two independent secrets holding two DIFFERENT values. Granting the
    # datastore's own password grants one the app never sends.
    test "grants the password the APP sends, not the datastore's own" do
      app_env = %{
        "DB_USERNAME" => "authair",
        "DB_PASSWORD" => "app-pw",
        "DB_DATABASE" => "authair"
      }

      datastore_env = %{
        "MARIADB_ROOT_PASSWORD" => "rootpw",
        "MARIADB_USER" => "authair",
        # A DIFFERENT value from DB_PASSWORD -- this is the trap.
        "MARIADB_PASSWORD" => "datastore-pw",
        "MARIADB_DATABASE" => "authair"
      }

      assert {:ok, creds} = Grants.credentials_from_env(app_env, datastore_env)

      assert creds.app_password == "app-pw",
             "granted the datastore's password; the app would still be denied"

      assert creds.admin_password == "rootpw"
      assert creds.app_user == "authair"
      assert creds.database == "authair"
    end

    test "falls back across the conventional spellings per app" do
      # Nextcloud-style app env.
      assert {:ok, %{app_user: "nc", app_password: "p", database: "nextcloud"}} =
               Grants.credentials_from_env(
                 %{
                   "MYSQL_USER" => "nc",
                   "MYSQL_PASSWORD" => "p",
                   "MYSQL_DATABASE" => "nextcloud"
                 },
                 %{"MYSQL_ROOT_PASSWORD" => "r"}
               )
    end

    test "explicit keys win over the fallbacks" do
      assert {:ok, %{app_password: "chosen"}} =
               Grants.credentials_from_env(
                 %{
                   "APP_DB_PW" => "chosen",
                   "DB_PASSWORD" => "ignored",
                   "DB_USERNAME" => "u",
                   "DB_DATABASE" => "d"
                 },
                 %{"MARIADB_ROOT_PASSWORD" => "r"},
                 %{"password" => "APP_DB_PW"}
               )
    end

    test "names exactly which values are missing" do
      assert {:error, {:missing_datastore_env, missing}} =
               Grants.credentials_from_env(%{"DB_USERNAME" => "authair"}, %{})

      assert "app password" in missing
      assert "database" in missing
      assert "datastore root password" in missing
      refute "app user" in missing
    end
  end
end
