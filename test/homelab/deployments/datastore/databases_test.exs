defmodule Homelab.Deployments.Datastore.DatabasesTest do
  @moduledoc """
  The declaration, and the SQL it turns into.

  The behaviour under test is the one an operator relies on months after first deploy:
  adding a name to `HOMELAB_DATABASES` has to create it, on a volume that already holds
  data, without anyone opening an SQL client. Every engine env that means "this database
  should exist" is first-init-only to the image itself, so these tests pin the part that
  makes those declarations keep meaning it.
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Datastore.Databases
  alias Homelab.Deployments.Datastore.Engine

  describe "declared/1" do
    test "splits a comma-separated list" do
      assert {:ok, ~w(sonarr-main sonarr-log radarr-main)} =
               Databases.declared(%{"HOMELAB_DATABASES" => "sonarr-main,sonarr-log,radarr-main"})
    end

    test "accepts spaces and newlines as separators" do
      assert {:ok, ~w(a b c)} = Databases.declared(%{"HOMELAB_DATABASES" => "a b\nc"})
    end

    test "hyphens are legal, because real apps ask for them" do
      assert {:ok, ["sonarr-main"]} = Databases.declared(%{"HOMELAB_DATABASES" => "sonarr-main"})
    end

    test "the engine's own first-init env is folded in, so it keeps meaning what it says" do
      assert {:ok, ["app"]} = Databases.declared(%{"POSTGRES_DB" => "app"})
      assert {:ok, ["app"]} = Databases.declared(%{"MARIADB_DATABASE" => "app"})
      assert {:ok, ["app"]} = Databases.declared(%{"MYSQL_DATABASE" => "app"})
    end

    test "a name declared twice is created once, and order is the declaration's" do
      assert {:ok, ["app", "logs"]} =
               Databases.declared(%{
                 "HOMELAB_DATABASES" => "app,logs,app",
                 "POSTGRES_DB" => "app"
               })
    end

    test "no declaration is no databases, not an error" do
      assert {:ok, []} = Databases.declared(%{})
      assert {:ok, []} = Databases.declared(%{"HOMELAB_DATABASES" => ""})
    end

    test "a name that could break out of the statement is refused, not escaped" do
      for name <- ["a\"; DROP DATABASE b; --", "a`b", "a'b", "-leading", "a b;c"] do
        assert {:error, {:invalid_database_name, _}} =
                 Databases.declared(%{"HOMELAB_DATABASES" => name}),
               "expected #{inspect(name)} to be refused"
      end
    end
  end

  describe "build_sql/2" do
    test "nothing declared builds no SQL, so no container is started to run it" do
      assert Databases.build_sql(Engine.Postgres, []) == nil
    end

    test "postgres guards each create, because it has no IF NOT EXISTS" do
      sql = Databases.build_sql(Engine.Postgres, ["sonarr-main"])

      assert sql =~ ~s|CREATE DATABASE "sonarr-main"|
      assert sql =~ ~s|WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = 'sonarr-main')|
      assert sql =~ "\\gexec"
    end

    test "mysql uses its native idempotent form" do
      assert Databases.build_sql(Engine.MySQL, ["app"]) =~ "CREATE DATABASE IF NOT EXISTS `app`;"
    end

    test "every declared database appears" do
      sql = Databases.build_sql(Engine.Postgres, ~w(a b c))

      for name <- ~w(a b c), do: assert(sql =~ ~s|CREATE DATABASE "#{name}"|)
    end
  end

  describe "engine resolution" do
    test "postgres and its derivatives resolve to the postgres engine" do
      for image <- ~w(postgres:18.6 timescale/timescaledb:2.17.2-pg17 postgis/postgis:16-3.4) do
        assert {:ok, Engine.Postgres} = Engine.for_image(image), "failed for #{image}"
      end
    end

    test "the mysql family resolves to the mysql engine" do
      for image <- ~w(mariadb:11 mysql:8 percona:8.0) do
        assert {:ok, Engine.MySQL} = Engine.for_image(image), "failed for #{image}"
      end
    end

    test "anything else is an explicit error, never a silent no-op" do
      assert {:error, {:unsupported_engine, _}} = Engine.for_image("redis:alpine")
    end

    test "the engines disagree about port and admin user, which is the point" do
      assert Engine.Postgres.default_port() == 5432
      assert Engine.MySQL.default_port() == 3306
      assert Engine.Postgres.admin_user(%{}) == "postgres"
      assert Engine.MySQL.admin_user(%{}) == "root"
    end

    test "postgres honours POSTGRES_USER when the image was given one" do
      assert Engine.Postgres.admin_user(%{"POSTGRES_USER" => "admin"}) == "admin"
    end

    test "each engine names the variable its client reads a password from" do
      assert Engine.Postgres.password_env() == "PGPASSWORD"
      assert Engine.MySQL.password_env() == "MYSQL_PWD"
    end

    test "the admin password comes from the engine's own spelling" do
      assert Engine.Postgres.admin_password(%{"POSTGRES_PASSWORD" => "s3cret"}) == "s3cret"
      assert Engine.MySQL.admin_password(%{"MARIADB_ROOT_PASSWORD" => "s3cret"}) == "s3cret"
      assert Engine.MySQL.admin_password(%{"MYSQL_ROOT_PASSWORD" => "s3cret"}) == "s3cret"
      assert Engine.Postgres.admin_password(%{}) == nil
    end
  end
end
