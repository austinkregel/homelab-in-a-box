defmodule Homelab.Catalog.Enrichers.DatabaseDetectorTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.DatabaseDetector

  describe "detect/1" do
    test "detects PostgreSQL from env vars" do
      env = [
        %{"key" => "POSTGRES_HOST", "value" => ""},
        %{"key" => "POSTGRES_PORT", "value" => ""},
        %{"key" => "POSTGRES_DB", "value" => "mydb"},
        %{"key" => "POSTGRES_USER", "value" => ""}
      ]

      results = DatabaseDetector.detect(env)
      assert length(results) > 0

      pg = Enum.find(results, &(&1.db_type == :postgres))
      assert pg != nil
      assert pg.label == "PostgreSQL"
      assert pg.image =~ "postgres"
    end

    test "detects MySQL from env vars" do
      env = [
        %{"key" => "MYSQL_HOST", "value" => ""},
        %{"key" => "MYSQL_DATABASE", "value" => "app"},
        %{"key" => "MYSQL_PASSWORD", "value" => ""}
      ]

      results = DatabaseDetector.detect(env)
      mysql = Enum.find(results, &(&1.db_type == :mysql))
      assert mysql != nil
      assert mysql.label == "MySQL"
    end

    test "detects Redis from env vars" do
      env = [
        %{"key" => "REDIS_HOST", "value" => ""},
        %{"key" => "REDIS_PORT", "value" => "6379"}
      ]

      results = DatabaseDetector.detect(env)
      redis = Enum.find(results, &(&1.db_type == :redis))
      assert redis != nil
    end

    test "returns empty list when no database env vars present" do
      env = [
        %{"key" => "APP_NAME", "value" => "test"},
        %{"key" => "PORT", "value" => "3000"}
      ]

      assert DatabaseDetector.detect(env) == []
    end

    test "includes wiring suggestions" do
      env = [
        %{"key" => "DB_HOST", "value" => ""},
        %{"key" => "DB_PORT", "value" => ""},
        %{"key" => "DB_DATABASE", "value" => ""}
      ]

      [result | _] = DatabaseDetector.detect(env)
      assert is_map(result.wiring)
      assert map_size(result.wiring) > 0
    end
  end

  describe "generate_secret/1" do
    test "generates a string of specified length" do
      secret = DatabaseDetector.generate_secret(24)
      assert is_binary(secret)
      assert String.length(secret) == 24
    end

    test "generates unique secrets" do
      a = DatabaseDetector.generate_secret()
      b = DatabaseDetector.generate_secret()
      assert a != b
    end
  end
end
