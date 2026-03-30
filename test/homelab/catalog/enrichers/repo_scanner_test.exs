defmodule Homelab.Catalog.Enrichers.RepoScannerTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.RepoScanner

  setup do
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    Application.put_env(:homelab, RepoScanner, base_url: base_url)

    on_exit(fn ->
      Application.delete_env(:homelab, RepoScanner)
    end)

    {:ok, bypass: bypass, base_url: base_url}
  end

  describe "scan/1" do
    test "returns error for non-GitHub URLs" do
      assert {:error, :not_a_github_url} = RepoScanner.scan("https://gitlab.com/owner/repo")
    end

    test "returns error for nil input" do
      assert {:error, :no_project_url} = RepoScanner.scan(nil)
    end

    test "returns error for non-string input" do
      assert {:error, :no_project_url} = RepoScanner.scan(123)
    end

    test "returns error for invalid URL format" do
      assert {:error, :not_a_github_url} = RepoScanner.scan("not-a-url")
    end

    test "parses .git suffix from URLs" do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"
      Application.put_env(:homelab, RepoScanner, base_url: base_url)

      Bypass.stub(bypass, "GET", "/owner/repo/main/docker-compose.yml", fn conn ->
        Plug.Conn.resp(conn, 200, """
        services:
          app:
            image: myapp:latest
            ports:
              - "8080:80"
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/owner/repo.git")
      assert is_map(result)
      assert result.setup_url == "https://github.com/owner/repo"
    end

    test "extracts compose file metadata", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/testorg/testrepo/main/docker-compose.yml", fn conn ->
        Plug.Conn.resp(conn, 200, """
        services:
          app:
            image: myapp:latest
            ports:
              - "8080:80"
            volumes:
              - ./data:/app/data
            environment:
              - DB_HOST=localhost
              - DB_PORT=5432
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/testorg/testrepo")
      assert length(result.ports) > 0
      assert length(result.volumes) > 0
      assert length(result.env) > 0
      assert result.setup_url == "https://github.com/testorg/testrepo"
    end

    test "falls back to master branch", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/org/repo/main/docker-compose.yml", fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      Bypass.stub(bypass, "GET", "/org/repo/master/docker-compose.yml", fn conn ->
        Plug.Conn.resp(conn, 200, """
        services:
          web:
            image: webapp:latest
            ports:
              - "3000:3000"
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo")
      assert length(result.ports) > 0
    end

    test "extracts env file variables", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/org/repo/main/.env.example", fn conn ->
        Plug.Conn.resp(conn, 200, """
        # Database configuration
        DB_HOST=localhost
        DB_PORT=5432
        DB_NAME="mydb"
        SECRET_KEY='s3cret'

        # Empty line above
        REDIS_URL=redis://localhost:6379
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo")
      keys = Enum.map(result.env, & &1["key"])
      assert "DB_HOST" in keys
      assert "DB_PORT" in keys
      assert "DB_NAME" in keys
      assert "SECRET_KEY" in keys
      assert "REDIS_URL" in keys

      db_name = Enum.find(result.env, &(&1["key"] == "DB_NAME"))
      assert db_name["value"] == "mydb"
    end

    test "extracts Dockerfile metadata", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/org/repo/main/Dockerfile", fn conn ->
        Plug.Conn.resp(conn, 200, """
        FROM node:18-alpine
        EXPOSE 3000
        EXPOSE 9229
        VOLUME /app/data
        ENV NODE_ENV=production
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo")
      assert length(result.ports) > 0 or length(result.env) > 0
    end

    test "merges data from compose and env file", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/org/repo/main/docker-compose.yml", fn conn ->
        Plug.Conn.resp(conn, 200, """
        services:
          app:
            image: myapp:latest
            ports:
              - "8080:80"
            environment:
              - DB_HOST=localhost
        """)
      end)

      Bypass.stub(bypass, "GET", "/org/repo/main/.env.example", fn conn ->
        Plug.Conn.resp(conn, 200, """
        DB_HOST=localhost
        EXTRA_VAR=value
        """)
      end)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo")
      keys = Enum.map(result.env, & &1["key"])
      assert "DB_HOST" in keys
      assert "EXTRA_VAR" in keys
    end

    test "handles all files returning 404", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo")
      assert result.ports == []
      assert result.volumes == []
      assert result.env == []
    end

    test "handles URL with hash fragment" do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"
      Application.put_env(:homelab, RepoScanner, base_url: base_url)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo#readme")
      assert result.setup_url == "https://github.com/org/repo"
    end

    test "handles URL with query params" do
      bypass = Bypass.open()
      base_url = "http://localhost:#{bypass.port}"
      Application.put_env(:homelab, RepoScanner, base_url: base_url)

      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 404, "Not found")
      end)

      {:ok, result} = RepoScanner.scan("https://github.com/org/repo?tab=readme")
      assert result.setup_url == "https://github.com/org/repo"
    end
  end
end
