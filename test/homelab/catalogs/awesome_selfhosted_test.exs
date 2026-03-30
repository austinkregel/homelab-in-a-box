defmodule Homelab.Catalogs.AwesomeSelfhostedTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureLog

  alias Homelab.Catalogs.AwesomeSelfhosted

  setup do
    :persistent_term.erase({AwesomeSelfhosted, :catalog})
    bypass = Bypass.open()
    base_url = "http://localhost:#{bypass.port}"
    Application.put_env(:homelab, AwesomeSelfhosted,
      github_api_url: base_url,
      raw_url: base_url
    )

    on_exit(fn ->
      :persistent_term.erase({AwesomeSelfhosted, :catalog})
      Application.delete_env(:homelab, AwesomeSelfhosted)
    end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "driver_id" do
      assert AwesomeSelfhosted.driver_id() == "awesome_selfhosted"
    end

    test "display_name" do
      assert AwesomeSelfhosted.display_name() == "Awesome-Selfhosted"
    end

    test "description" do
      assert is_binary(AwesomeSelfhosted.description())
    end
  end

  describe "browse/1" do
    test "fetches and parses entries from GitHub", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        cond do
          String.contains?(conn.request_path, "/git/trees/") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{
              "tree" => [
                %{"path" => "software/nextcloud.yml", "type" => "blob"},
                %{"path" => "software/gitea.yml", "type" => "blob"},
                %{"path" => "README.md", "type" => "blob"}
              ]
            }))

          String.contains?(conn.request_path, "nextcloud.yml") ->
            Plug.Conn.resp(conn, 200, """
            name: Nextcloud
            description: A safe home for all your data
            website_url: https://nextcloud.com
            source_code_url: https://github.com/nextcloud/server
            tags:
              - Cloud Storage
              - File Sharing
            platforms:
              - amd64
              - arm64
            """)

          String.contains?(conn.request_path, "gitea.yml") ->
            Plug.Conn.resp(conn, 200, """
            name: Gitea
            description: A painless self-hosted Git service
            website_url: https://gitea.io
            source_code_url: https://github.com/go-gitea/gitea
            tags:
              - Development
              - Git
            platforms:
              - amd64
            """)

          true ->
            Plug.Conn.resp(conn, 404, "Not found")
        end
      end)

      {:ok, entries} = AwesomeSelfhosted.browse()
      assert length(entries) == 2

      nc = Enum.find(entries, &(&1.name == "Nextcloud"))
      assert nc.source == "awesome_selfhosted"
      assert nc.description =~ "safe home"
      assert "Cloud Storage" in nc.categories
      assert nc.full_ref =~ "ghcr.io"
    end

    test "returns cached entries when available" do
      entries = [
        %Homelab.Catalog.CatalogEntry{
          name: "CachedApp",
          source: "awesome_selfhosted",
          description: "Cached"
        }
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, result} = AwesomeSelfhosted.browse()
      assert hd(result).name == "CachedApp"
    end

    test "handles API error", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        Plug.Conn.resp(conn, 500, "Server Error")
      end)

      log =
        capture_log(fn ->
          assert {:error, _} = AwesomeSelfhosted.browse()
        end)

      assert log =~ "retry: got response with status 500, will retry in"
      assert log =~ "3 attempts left"
      assert log =~ "1 attempt left"
    end

    test "skips entries without names", %{bypass: bypass} do
      Bypass.stub(bypass, :any, :any, fn conn ->
        cond do
          String.contains?(conn.request_path, "/git/trees/") ->
            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.resp(200, Jason.encode!(%{
              "tree" => [%{"path" => "software/noname.yml", "type" => "blob"}]
            }))

          String.contains?(conn.request_path, "noname.yml") ->
            Plug.Conn.resp(conn, 200, """
            description: Has no name field
            website_url: https://example.com
            """)

          true ->
            Plug.Conn.resp(conn, 404, "Not found")
        end
      end)

      {:ok, entries} = AwesomeSelfhosted.browse()
      assert entries == []
    end

    test "infers Docker image from GitHub source URL" do
      entries = [
        %Homelab.Catalog.CatalogEntry{
          name: "TestApp",
          source: "awesome_selfhosted",
          full_ref: "ghcr.io/owner/repo:latest"
        }
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, result} = AwesomeSelfhosted.browse()
      assert hd(result).full_ref =~ "ghcr.io"
    end
  end

  describe "search/2" do
    test "filters by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "Nextcloud", description: "Cloud", categories: ["Cloud"]},
        %Homelab.Catalog.CatalogEntry{name: "Gitea", description: "Git", categories: ["Dev"]}
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, results} = AwesomeSelfhosted.search("next")
      assert length(results) == 1
      assert hd(results).name == "Nextcloud"
    end

    test "filters by description" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "Nextcloud", description: "Cloud storage", categories: []},
        %Homelab.Catalog.CatalogEntry{name: "Gitea", description: "Git hosting", categories: []}
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, results} = AwesomeSelfhosted.search("git")
      assert length(results) == 1
    end

    test "filters by category" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "Nextcloud", description: "Cloud", categories: ["Cloud Storage"]},
        %Homelab.Catalog.CatalogEntry{name: "Gitea", description: "Git", categories: ["Development"]}
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, results} = AwesomeSelfhosted.search("development")
      assert length(results) == 1
    end
  end

  describe "app_details/1" do
    test "returns entry by name" do
      entries = [
        %Homelab.Catalog.CatalogEntry{name: "Nextcloud", description: "Cloud"},
        %Homelab.Catalog.CatalogEntry{name: "Gitea", description: "Git"}
      ]

      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      {:ok, entry} = AwesomeSelfhosted.app_details("Gitea")
      assert entry.name == "Gitea"
    end

    test "returns not_found for unknown" do
      entries = [%Homelab.Catalog.CatalogEntry{name: "Nextcloud", description: "Cloud"}]
      :persistent_term.put({AwesomeSelfhosted, :catalog}, entries)

      assert {:error, :not_found} = AwesomeSelfhosted.app_details("nope")
    end
  end
end
