defmodule Homelab.Catalogs.HotioTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Homelab.Catalogs.Hotio

  setup do
    :persistent_term.erase({Hotio, :catalog})
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    Application.put_env(:homelab, Hotio, base_url: base_url)

    on_exit(fn ->
      :persistent_term.erase({Hotio, :catalog})
      Application.delete_env(:homelab, Hotio)
    end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "driver_id" do
      assert Hotio.driver_id() == "hotio"
    end

    test "display_name" do
      assert Hotio.display_name() == "Hotio"
    end

    test "description" do
      assert is_binary(Hotio.description())
    end
  end

  describe "browse/1" do
    test "fetches and parses repos from Docker Hub", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "results" => [
            %{"name" => "radarr", "description" => "Movie automation", "star_count" => 50, "pull_count" => 100000},
            %{"name" => "sonarr", "description" => "TV automation", "star_count" => 40, "pull_count" => 80000},
            %{"name" => "plex", "description" => "Media server", "star_count" => 30, "pull_count" => 60000}
          ],
          "next" => nil
        }))
      end)

      {:ok, entries} = Hotio.browse()
      assert length(entries) == 3

      radarr = Enum.find(entries, &(&1.name == "radarr"))
      assert radarr.namespace == "hotio"
      assert radarr.source == "hotio"
      assert radarr.full_ref == "ghcr.io/hotio/radarr:latest"
      assert "Automation" in radarr.categories
    end

    test "categorizes apps correctly" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "plex", categories: ["Media"]},
        %Homelab.Catalog.CatalogEntry{name: "radarr", categories: ["Automation"]},
        %Homelab.Catalog.CatalogEntry{name: "qbittorrent", categories: ["Downloads"]},
        %Homelab.Catalog.CatalogEntry{name: "jackett", categories: ["Indexers"]},
        %Homelab.Catalog.CatalogEntry{name: "autoscan", categories: ["Utilities"]},
        %Homelab.Catalog.CatalogEntry{name: "unknown-app", categories: ["Other"]}
      ]

      :persistent_term.put({Hotio, :catalog}, entries)

      {:ok, result} = Hotio.browse()
      plex = Enum.find(result, &(&1.name == "plex"))
      assert "Media" in plex.categories
    end

    test "handles pagination", %{bypass: bypass} do
      call_count = :counters.new(1, [:atomics])

      Bypass.stub(bypass, :any, :any, fn conn ->
        :counters.add(call_count, 1, 1)
        count = :counters.get(call_count, 1)

        body =
          if count == 1 do
            %{
              "results" => [%{"name" => "radarr", "description" => "Movie", "star_count" => 1, "pull_count" => 1}],
              "next" => "http://localhost:#{bypass.port}/v2/repositories/hotio/?page=2"
            }
          else
            %{
              "results" => [%{"name" => "sonarr", "description" => "TV", "star_count" => 1, "pull_count" => 1}],
              "next" => nil
            }
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(body))
      end)

      {:ok, entries} = Hotio.browse()
      assert length(entries) == 2
    end

    test "handles HTTP error on first page", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 500, "Server Error")
      end)

      log =
        capture_log(fn ->
          assert {:error, {:http_error, 500}} = Hotio.browse()
        end)

      assert log =~ "retry: got response with status 500, will retry in"
      assert log =~ "3 attempts left"
      assert log =~ "1 attempt left"
    end
  end

  describe "search/2" do
    test "filters by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "radarr", description: "Movie automation", categories: ["Automation"]},
        %Homelab.Catalog.CatalogEntry{name: "sonarr", description: "TV automation", categories: ["Automation"]}
      ]

      :persistent_term.put({Hotio, :catalog}, entries)

      {:ok, results} = Hotio.search("radarr")
      assert length(results) == 1
      assert hd(results).name == "radarr"
    end

    test "filters by category" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "plex", description: "Media", categories: ["Media"]},
        %Homelab.Catalog.CatalogEntry{name: "radarr", description: "Automation", categories: ["Automation"]}
      ]

      :persistent_term.put({Hotio, :catalog}, entries)

      {:ok, results} = Hotio.search("media")
      assert length(results) == 1
    end
  end

  describe "app_details/1" do
    test "returns entry by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "radarr", description: "Movies"},
        %Homelab.Catalog.CatalogEntry{name: "sonarr", description: "TV"}
      ]

      :persistent_term.put({Hotio, :catalog}, entries)

      {:ok, entry} = Hotio.app_details("radarr")
      assert entry.name == "radarr"
    end

    test "returns not_found for unknown" do
      entries = [%Homelab.Catalog.CatalogEntry{name: "radarr", description: "Movies"}]
      :persistent_term.put({Hotio, :catalog}, entries)

      assert {:error, :not_found} = Hotio.app_details("nope")
    end
  end
end
