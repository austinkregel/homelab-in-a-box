defmodule Homelab.Catalog.Enrichers.ComposeParserTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.ComposeParser

  @basic_compose """
  services:
    app:
      image: nginx:latest
      ports:
        - "8080:80"
      volumes:
        - ./data:/data
      environment:
        - APP_ENV=production
        - SECRET_KEY=mysecret
  """

  @compose_with_db """
  services:
    web:
      image: myapp:latest
      ports:
        - "3000:3000"
      depends_on:
        - db
    db:
      image: postgres:16
      ports:
        - "5432:5432"
  """

  @compose_map_env """
  services:
    app:
      image: myapp:latest
      environment:
        APP_ENV: production
        DB_HOST: localhost
        DB_PORT: 5432
  """

  @compose_map_ports """
  services:
    app:
      image: myapp:latest
      ports:
        - target: 80
          published: 8080
        - target: 443
          published: 8443
  """

  @compose_map_volumes """
  services:
    app:
      image: myapp:latest
      volumes:
        - type: bind
          source: ./data
          target: /app/data
        - type: volume
          source: logs
          target: /var/log
  """

  @compose_integer_ports """
  services:
    app:
      image: myapp:latest
      ports:
        - 8080
        - 3000
  """

  @compose_host_ip_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "127.0.0.1:8080:80"
  """

  @compose_protocol_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "8080:80/tcp"
        - "9090:90/udp"
  """

  @compose_depends_on_map """
  services:
    app:
      image: myapp:latest
      depends_on:
        db:
          condition: service_healthy
        redis:
          condition: service_started
  """

  @compose_no_services """
  version: "3"
  networks:
    default:
      driver: bridge
  """

  @compose_all_db """
  services:
    postgres:
      image: postgres:16
    redis:
      image: redis:7
  """

  @compose_single_port """
  services:
    app:
      image: myapp:latest
      ports:
        - "80"
  """

  @compose_volume_absolute """
  services:
    app:
      image: myapp:latest
      volumes:
        - /var/data
  """

  @compose_volume_named """
  services:
    app:
      image: myapp:latest
      volumes:
        - mydata
  """

  @compose_env_no_value """
  services:
    app:
      image: myapp:latest
      environment:
        - SECRET_KEY
  """

  describe "parse/1" do
    test "extracts ports from compose" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      assert length(result.ports) > 0
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "8080"
    end

    test "extracts volumes from compose" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      assert length(result.volumes) > 0
      assert hd(result.volumes)["path"] == "/data"
    end

    test "extracts environment variables" do
      {:ok, result} = ComposeParser.parse(@basic_compose)
      keys = Enum.map(result.env, & &1["key"])
      assert "APP_ENV" in keys
      assert "SECRET_KEY" in keys
    end

    test "picks non-db service as primary" do
      {:ok, result} = ComposeParser.parse(@compose_with_db)
      assert hd(result.ports)["internal"] == "3000"
    end

    test "extracts depends_on" do
      {:ok, result} = ComposeParser.parse(@compose_with_db)
      assert "db" in result.depends_on
    end

    test "returns error for invalid YAML" do
      assert {:error, _} = ComposeParser.parse("invalid: [yaml: {broken")
    end

    test "parses map-style environment variables" do
      {:ok, result} = ComposeParser.parse(@compose_map_env)
      keys = Enum.map(result.env, & &1["key"])
      assert "APP_ENV" in keys
      assert "DB_HOST" in keys
      assert "DB_PORT" in keys
      db_port = Enum.find(result.env, &(&1["key"] == "DB_PORT"))
      assert db_port["value"] == "5432"
    end

    test "parses map-style ports" do
      {:ok, result} = ComposeParser.parse(@compose_map_ports)
      assert length(result.ports) == 2
      port = Enum.find(result.ports, &(&1["internal"] == "80"))
      assert port["external"] == "8080"
    end

    test "parses map-style volumes" do
      {:ok, result} = ComposeParser.parse(@compose_map_volumes)
      assert length(result.volumes) == 2
      paths = Enum.map(result.volumes, & &1["path"])
      assert "/app/data" in paths
      assert "/var/log" in paths
    end

    test "parses integer ports" do
      {:ok, result} = ComposeParser.parse(@compose_integer_ports)
      assert length(result.ports) == 2
      internals = Enum.map(result.ports, & &1["internal"])
      assert "8080" in internals
      assert "3000" in internals
    end

    test "parses host-ip:external:internal port format" do
      {:ok, result} = ComposeParser.parse(@compose_host_ip_port)
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "8080"
    end

    test "strips protocol from port strings" do
      {:ok, result} = ComposeParser.parse(@compose_protocol_port)
      assert length(result.ports) == 2
      port = Enum.find(result.ports, &(&1["internal"] == "80"))
      assert port["external"] == "8080"
    end

    test "parses depends_on as map with conditions" do
      {:ok, result} = ComposeParser.parse(@compose_depends_on_map)
      assert "db" in result.depends_on
      assert "redis" in result.depends_on
    end

    test "returns empty result for YAML with no services" do
      {:ok, result} = ComposeParser.parse(@compose_no_services)
      assert result.ports == []
      assert result.volumes == []
      assert result.env == []
      assert result.depends_on == []
    end

    test "falls back to first service when all are DB" do
      {:ok, result} = ComposeParser.parse(@compose_all_db)
      assert is_list(result.ports)
    end

    test "parses single port string" do
      {:ok, result} = ComposeParser.parse(@compose_single_port)
      port = hd(result.ports)
      assert port["internal"] == "80"
      assert port["external"] == "80"
    end

    test "parses absolute volume path" do
      {:ok, result} = ComposeParser.parse(@compose_volume_absolute)
      assert length(result.volumes) == 1
      assert hd(result.volumes)["path"] == "/var/data"
    end

    test "ignores named volumes without leading slash" do
      {:ok, result} = ComposeParser.parse(@compose_volume_named)
      assert result.volumes == []
    end

    test "env var without value gets empty string" do
      {:ok, result} = ComposeParser.parse(@compose_env_no_value)
      env = Enum.find(result.env, &(&1["key"] == "SECRET_KEY"))
      assert env["value"] == ""
    end
  end

  describe "parse_all/1" do
    test "returns all services" do
      {:ok, services} = ComposeParser.parse_all(@compose_with_db)
      assert length(services) == 2
      names = Enum.map(services, & &1.name)
      assert "web" in names
      assert "db" in names
    end

    test "each service has expected fields" do
      {:ok, services} = ComposeParser.parse_all(@compose_with_db)
      web = Enum.find(services, &(&1.name == "web"))
      assert is_list(web.ports)
      assert is_list(web.volumes)
      assert is_list(web.env)
      assert is_list(web.depends_on)
      assert web.image == "myapp:latest"
    end

    test "returns empty list for YAML without services" do
      {:ok, services} = ComposeParser.parse_all(@compose_no_services)
      assert services == []
    end

    test "returns error for invalid YAML" do
      assert {:error, _} = ComposeParser.parse_all("{{invalid")
    end
  end
end
