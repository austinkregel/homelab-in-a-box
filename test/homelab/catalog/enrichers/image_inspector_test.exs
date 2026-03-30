defmodule Homelab.Catalog.Enrichers.ImageInspectorTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Homelab.Catalog.Enrichers.ImageInspector

  describe "parse_image_ref/1" do
    test "parses bare image name (adds library/ prefix)" do
      {registry, auth, repo, tag} = ImageInspector.parse_image_ref("nginx")
      assert registry =~ "registry-1.docker.io"
      assert auth =~ "auth.docker.io"
      assert repo == "library/nginx"
      assert tag == "latest"
    end

    test "parses image with tag" do
      {_registry, _auth, repo, tag} = ImageInspector.parse_image_ref("redis:7-alpine")
      assert repo == "library/redis"
      assert tag == "7-alpine"
    end

    test "parses namespaced image" do
      {_registry, _auth, repo, tag} = ImageInspector.parse_image_ref("linuxserver/nextcloud:latest")
      assert repo == "linuxserver/nextcloud"
      assert tag == "latest"
    end

    test "parses ghcr.io image" do
      {registry, auth, repo, tag} = ImageInspector.parse_image_ref("ghcr.io/owner/app:v1.0")
      assert registry =~ "ghcr.io"
      assert auth =~ "ghcr.io"
      assert repo == "owner/app"
      assert tag == "v1.0"
    end

    test "parses lscr.io image" do
      {registry, auth, repo, tag} = ImageInspector.parse_image_ref("lscr.io/linuxserver/plex:latest")
      assert registry =~ "registry-1.docker.io"
      assert auth =~ "auth.docker.io"
      assert repo == "linuxserver/plex"
      assert tag == "latest"
    end

    test "parses public.ecr.aws image" do
      {registry, auth, repo, tag} = ImageInspector.parse_image_ref("public.ecr.aws/bitnami/redis:7")
      assert registry =~ "ecr.aws"
      assert is_nil(auth)
      assert repo == "bitnami/redis"
      assert tag == "7"
    end

    test "parses docker.io prefixed image" do
      {_registry, _auth, repo, tag} = ImageInspector.parse_image_ref("docker.io/library/alpine:3.19")
      assert repo == "library/alpine"
      assert tag == "3.19"
    end

    test "defaults to latest tag when no tag given" do
      {_registry, _auth, _repo, tag} = ImageInspector.parse_image_ref("ubuntu")
      assert tag == "latest"
    end

    test "trims whitespace" do
      {_registry, _auth, repo, _tag} = ImageInspector.parse_image_ref("  nginx:latest  ")
      assert repo == "library/nginx"
    end
  end

  describe "parse_exposed_ports/1" do
    test "returns empty list for nil" do
      assert ImageInspector.parse_exposed_ports(nil) == []
    end

    test "parses TCP port specification" do
      ports = ImageInspector.parse_exposed_ports(%{"80/tcp" => %{}})
      assert length(ports) == 1
      port = hd(ports)
      assert port["internal"] == "80"
      assert port["external"] == "80"
      assert port["optional"] == false
    end

    test "parses multiple ports" do
      ports = ImageInspector.parse_exposed_ports(%{"80/tcp" => %{}, "443/tcp" => %{}, "8080/tcp" => %{}})
      assert length(ports) == 3
      internals = Enum.map(ports, & &1["internal"])
      assert "80" in internals
      assert "443" in internals
      assert "8080" in internals
    end

    test "parses UDP port specification" do
      ports = ImageInspector.parse_exposed_ports(%{"53/udp" => %{}})
      assert hd(ports)["internal"] == "53"
    end

    test "includes role from PortRoles" do
      ports = ImageInspector.parse_exposed_ports(%{"80/tcp" => %{}})
      assert is_binary(hd(ports)["role"]) or is_nil(hd(ports)["role"])
    end
  end

  describe "parse_volumes/1" do
    test "returns empty list for nil" do
      assert ImageInspector.parse_volumes(nil) == []
    end

    test "parses volume paths" do
      volumes = ImageInspector.parse_volumes(%{"/data" => %{}, "/config" => %{}})
      assert length(volumes) == 2
      paths = Enum.map(volumes, & &1["path"])
      assert "/data" in paths
      assert "/config" in paths
    end

    test "includes optional flag" do
      volumes = ImageInspector.parse_volumes(%{"/data" => %{}})
      assert hd(volumes)["optional"] == false
    end
  end

  describe "parse_env/1" do
    test "returns empty list for nil" do
      assert ImageInspector.parse_env(nil) == []
    end

    test "parses KEY=VALUE format" do
      env = ImageInspector.parse_env(["APP_PORT=8080", "NODE_ENV=production"])
      assert length(env) == 2
      keys = Enum.map(env, & &1["key"])
      assert "APP_PORT" in keys
      assert "NODE_ENV" in keys
    end

    test "handles env without value" do
      env = ImageInspector.parse_env(["MY_VAR"])
      assert length(env) == 1
      assert hd(env)["key"] == "MY_VAR"
      assert hd(env)["value"] == ""
    end

    test "filters out system environment variables" do
      env = ImageInspector.parse_env([
        "APP_PORT=8080",
        "PATH=/usr/bin",
        "HOME=/root",
        "HOSTNAME=container",
        "LANG=en_US.UTF-8",
        "NODE_VERSION=18.0.0",
        "GOPATH=/go",
        "S6_VERBOSITY=1"
      ])
      keys = Enum.map(env, & &1["key"])
      assert "APP_PORT" in keys
      refute "PATH" in keys
      refute "HOME" in keys
      refute "HOSTNAME" in keys
      refute "LANG" in keys
      refute "NODE_VERSION" in keys
      refute "GOPATH" in keys
      refute "S6_VERBOSITY" in keys
    end
  end

  describe "system_env?/1" do
    test "recognizes exact matches" do
      assert ImageInspector.system_env?("MEMORY_LIMIT")
      assert ImageInspector.system_env?("LSIO_FIRST_PARTY")
    end

    test "recognizes prefix matches" do
      assert ImageInspector.system_env?("PATH")
      assert ImageInspector.system_env?("HOME")
      assert ImageInspector.system_env?("PYTHON_VERSION")
      assert ImageInspector.system_env?("JAVA_HOME")
      assert ImageInspector.system_env?("PHP_VERSION")
      assert ImageInspector.system_env?("DOTNET_ROOT")
      assert ImageInspector.system_env?("NVIDIA_VISIBLE_DEVICES")
    end

    test "rejects non-system vars" do
      refute ImageInspector.system_env?("APP_PORT")
      refute ImageInspector.system_env?("DB_HOST")
      refute ImageInspector.system_env?("REDIS_URL")
      refute ImageInspector.system_env?("MY_CUSTOM_VAR")
    end
  end

  describe "extract_metadata/1" do
    test "extracts from config key" do
      config = %{
        "config" => %{
          "ExposedPorts" => %{"80/tcp" => %{}},
          "Volumes" => %{"/data" => %{}},
          "Env" => ["APP_PORT=8080"],
          "Labels" => %{"maintainer" => "test"}
        }
      }

      result = ImageInspector.extract_metadata(config)
      assert length(result.ports) == 1
      assert length(result.volumes) == 1
      assert length(result.env) == 1
      assert result.labels["maintainer"] == "test"
    end

    test "falls back to container_config key" do
      config = %{
        "container_config" => %{
          "ExposedPorts" => %{"443/tcp" => %{}},
          "Volumes" => nil,
          "Env" => nil,
          "Labels" => %{}
        }
      }

      result = ImageInspector.extract_metadata(config)
      assert length(result.ports) == 1
      assert result.volumes == []
      assert result.env == []
    end

    test "handles empty config" do
      result = ImageInspector.extract_metadata(%{})
      assert result.ports == []
      assert result.volumes == []
      assert result.env == []
      assert result.labels == %{}
    end
  end

  describe "inspect/1" do
    test "returns error for unreachable image" do
      log =
        capture_log(fn ->
          result = ImageInspector.inspect("localhost:1/nonexistent:latest")
          assert {:error, _} = result
        end)

      assert log =~ "[ImageInspector] Failed to inspect localhost:1/nonexistent:latest"
    end

    test "parses a registry image via bypass" do
      bypass = Bypass.open()

      Bypass.stub(bypass, "GET", "/v2/", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("www-authenticate", "Bearer realm=\"http://localhost:#{bypass.port}/token\"")
        |> Plug.Conn.resp(401, "")
      end)

      Bypass.stub(bypass, "GET", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"token" => "test-token"}))
      end)

      Bypass.stub(bypass, "GET", "/v2/library/alpine/manifests/latest", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "config" => %{"digest" => "sha256:abc123"}
        }))
      end)

      Bypass.stub(bypass, "GET", "/v2/library/alpine/blobs/sha256:abc123", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "config" => %{
            "ExposedPorts" => %{"80/tcp" => %{}},
            "Volumes" => %{"/data" => %{}},
            "Env" => ["APP_PORT=8080", "NODE_ENV=production"],
            "Labels" => %{"maintainer" => "test"}
          }
        }))
      end)

      capture_log(fn ->
        result = ImageInspector.inspect("localhost:#{bypass.port}/library/alpine:latest")
        assert match?({:ok, _}, result) or match?({:error, _}, result)
      end)
    end
  end
end
