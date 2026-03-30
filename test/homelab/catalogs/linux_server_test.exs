defmodule Homelab.Catalogs.LinuxServerTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Homelab.Catalogs.LinuxServer

  setup do
    :persistent_term.erase({LinuxServer, :catalog})
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    Application.put_env(:homelab, LinuxServer, base_url: base_url)

    on_exit(fn ->
      :persistent_term.erase({LinuxServer, :catalog})
      Application.delete_env(:homelab, LinuxServer)
    end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "driver_id" do
      assert LinuxServer.driver_id() == "linuxserver"
    end

    test "display_name" do
      assert LinuxServer.display_name() == "LinuxServer.io"
    end

    test "description" do
      assert is_binary(LinuxServer.description())
    end
  end

  describe "browse/1" do
    test "fetches and parses images from API", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/images", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "OK",
          "data" => %{
            "repositories" => %{
              "linuxserver" => [
                %{
                  "name" => "nextcloud",
                  "description" => "A self-hosted productivity platform",
                  "project_logo" => "https://example.com/logo.png",
                  "version" => "29.0.0",
                  "project_url" => "https://nextcloud.com",
                  "stars" => 100,
                  "monthly_pulls" => 50000,
                  "deprecated" => false,
                  "category" => "Cloud, Productivity",
                  "architectures" => [%{"arch" => "amd64"}, %{"arch" => "arm64"}],
                  "config" => %{
                    "application_setup" => "https://docs.nextcloud.com",
                    "volumes" => [
                      %{"path" => "/config", "desc" => "Config files", "optional" => false},
                      %{"path" => "/data", "desc" => "User data", "optional" => false}
                    ],
                    "ports" => [
                      %{"internal" => "443", "external" => "443", "desc" => "HTTPS", "optional" => false}
                    ]
                  }
                },
                %{
                  "name" => "plex",
                  "description" => "Media server",
                  "project_logo" => nil,
                  "version" => "1.40",
                  "project_url" => "https://plex.tv",
                  "stars" => 200,
                  "monthly_pulls" => 100000,
                  "deprecated" => false,
                  "category" => "Media",
                  "architectures" => [%{"arch" => "amd64"}],
                  "config" => %{}
                }
              ]
            }
          }
        }))
      end)

      {:ok, entries} = LinuxServer.browse()
      assert length(entries) == 2

      nc = Enum.find(entries, &(&1.name == "nextcloud"))
      assert nc.namespace == "linuxserver"
      assert nc.source == "linuxserver"
      assert nc.full_ref == "lscr.io/linuxserver/nextcloud:latest"
      assert nc.description =~ "productivity"
      assert length(nc.categories) == 2
      assert "Cloud" in nc.categories
      assert length(nc.architectures) == 2
      assert length(nc.required_ports) == 1
      assert length(nc.required_volumes) == 2
      assert nc.default_env["PUID"] == "1000"
    end

    test "caches results in persistent_term", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/images", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "status" => "OK",
          "data" => %{"repositories" => %{"linuxserver" => [
            %{"name" => "test", "description" => "Test", "config" => %{}, "category" => "Test"}
          ]}}
        }))
      end)

      {:ok, _} = LinuxServer.browse()
      cached = :persistent_term.get({LinuxServer, :catalog})
      assert length(cached) == 1
    end

    test "returns cached entries when available" do
      entries = [
        %Homelab.Catalog.CatalogEntry{
          name: "cached-app",
          namespace: "linuxserver",
          source: "linuxserver",
          description: "From cache",
          full_ref: "lscr.io/linuxserver/cached-app:latest"
        }
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, result} = LinuxServer.browse()
      assert hd(result).name == "cached-app"
    end

    test "handles HTTP error", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/images", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      log =
        capture_log(fn ->
          assert {:error, {:http_error, 500}} = LinuxServer.browse()
        end)

      assert log =~ "retry: got response with status 500, will retry in"
      assert log =~ "3 attempts left"
      assert log =~ "1 attempt left"
    end

    test "handles unexpected response format", %{bypass: bypass} do
      Bypass.stub(bypass, "GET", "/api/v1/images", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"status" => "ERROR"}))
      end)

      {:ok, entries} = LinuxServer.browse()
      assert entries == []
    end
  end

  describe "search/2" do
    test "filters entries by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "nextcloud", description: "Cloud storage", categories: ["Cloud"]},
        %Homelab.Catalog.CatalogEntry{name: "plex", description: "Media server", categories: ["Media"]}
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, results} = LinuxServer.search("next")
      assert length(results) == 1
      assert hd(results).name == "nextcloud"
    end

    test "filters entries by description" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "nextcloud", description: "Cloud storage", categories: []},
        %Homelab.Catalog.CatalogEntry{name: "plex", description: "Media server", categories: []}
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, results} = LinuxServer.search("media")
      assert length(results) == 1
      assert hd(results).name == "plex"
    end

    test "filters entries by category" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "nextcloud", description: "Cloud", categories: ["Cloud", "Productivity"]},
        %Homelab.Catalog.CatalogEntry{name: "plex", description: "Media", categories: ["Media"]}
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, results} = LinuxServer.search("productivity")
      assert length(results) == 1
    end

    test "case-insensitive search" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "NextCloud", description: "Cloud", categories: []}
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, results} = LinuxServer.search("NEXTCLOUD")
      assert length(results) == 1
    end
  end

  describe "app_details/1" do
    test "returns entry by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "nextcloud", description: "Cloud"},
        %Homelab.Catalog.CatalogEntry{name: "plex", description: "Media"}
      ]

      :persistent_term.put({LinuxServer, :catalog}, entries)

      {:ok, entry} = LinuxServer.app_details("plex")
      assert entry.name == "plex"
    end

    test "returns error for unknown app" do
      entries = [%Homelab.Catalog.CatalogEntry{name: "nextcloud", description: "Cloud"}]
      :persistent_term.put({LinuxServer, :catalog}, entries)

      assert {:error, :not_found} = LinuxServer.app_details("nonexistent")
    end
  end
end
