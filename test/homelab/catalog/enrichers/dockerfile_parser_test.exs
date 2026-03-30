defmodule Homelab.Catalog.Enrichers.DockerfileParserTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.DockerfileParser

  @dockerfile """
  FROM node:20-alpine
  ENV APP_PORT=3000
  ENV NODE_ENV=production
  EXPOSE 3000
  EXPOSE 8080/tcp
  VOLUME /data
  VOLUME ["/config", "/logs"]
  CMD ["node", "server.js"]
  """

  describe "parse/1" do
    test "extracts EXPOSE ports" do
      {:ok, result} = DockerfileParser.parse(@dockerfile)
      ports = Enum.map(result.ports, & &1["internal"])
      assert "3000" in ports
      assert "8080" in ports
    end

    test "extracts VOLUME paths" do
      {:ok, result} = DockerfileParser.parse(@dockerfile)
      paths = Enum.map(result.volumes, & &1["path"])
      assert "/data" in paths
      assert "/config" in paths
      assert "/logs" in paths
    end

    test "extracts ENV variables" do
      {:ok, result} = DockerfileParser.parse(@dockerfile)
      keys = Enum.map(result.env, & &1["key"])
      assert "APP_PORT" in keys
      assert "NODE_ENV" in keys
    end

    test "filters system env variables" do
      {:ok, result} = DockerfileParser.parse("FROM alpine\nENV PATH=/usr/bin\nENV MY_VAR=hello")
      keys = Enum.map(result.env, & &1["key"])
      refute "PATH" in keys
      assert "MY_VAR" in keys
    end

    test "handles empty Dockerfile" do
      {:ok, result} = DockerfileParser.parse("FROM alpine")
      assert result.ports == []
      assert result.volumes == []
      assert result.env == []
    end
  end
end
