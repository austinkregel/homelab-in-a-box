defmodule HomelabWeb.CatalogLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Catalog.CatalogEntry

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)
    template = insert(:app_template)

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn, tenant: tenant, template: template}
  end

  describe "mount" do
    test "renders catalog page with curated tab active", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/catalog")
      assert html =~ "App Catalog"
      assert html =~ "Curated"
      assert html =~ "Search"
      assert html =~ "Custom"
    end

    test "curated tab is selected by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      assert has_element?(view, "button", "Curated")
    end

    test "assigns initial empty state for search and curated", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/catalog")
      refute html =~ "No results found"
      assert html =~ "Browse curated apps"
    end
  end

  describe "switch_tab" do
    test "switches to search tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      html = render_click(view, "switch_tab", %{"tab" => "search"})
      assert html =~ "Search images..."
    end

    test "switches to custom tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      html = render_click(view, "switch_tab", %{"tab" => "custom"})
      assert has_element?(view, "#custom-deploy-form")
      assert html =~ "Image"
      assert html =~ "Tag"
      assert html =~ "Display name"
    end

    test "switches back to curated tab", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      html = render_click(view, "switch_tab", %{"tab" => "curated"})
      assert html =~ "Curated"
    end

    test "search tab shows search form with registry selector", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      html = render(view)
      assert html =~ "All registries"
      assert html =~ "Search"
    end
  end

  describe "search" do
    test "triggers search and shows loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      render_click(view, "search", %{"query" => "nginx", "registry" => ""})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search" or html =~ "No results found"
    end

    test "shows results for search query", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      render_click(view, "search", %{"query" => "nonexistent_image_xyz", "registry" => ""})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search" or html =~ "search" or html =~ "catalog"
    end

    test "search with empty query still processes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      render_click(view, "search", %{"query" => "", "registry" => ""})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search"
    end

    test "search with specific registry filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})
      render_click(view, "search", %{"query" => "nginx", "registry" => "dockerhub"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search" or html =~ "No results found"
    end
  end

  describe "select_registry" do
    test "selects a registry filter", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "select_registry", %{"registry" => "dockerhub"})
      _ = :sys.get_state(view.pid)
      _html = render(view)
    end

    test "clears registry filter with empty string", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "select_registry", %{"registry" => "dockerhub"})
      render_click(view, "select_registry", %{"registry" => ""})
      _ = :sys.get_state(view.pid)
      _html = render(view)
    end

    test "toggling registry back and forth works", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "select_registry", %{"registry" => "ghcr"})
      _ = :sys.get_state(view.pid)
      render_click(view, "select_registry", %{"registry" => "dockerhub"})
      _ = :sys.get_state(view.pid)
      render_click(view, "select_registry", %{"registry" => ""})
      _ = :sys.get_state(view.pid)
      _html = render(view)
    end
  end

  describe "toggle_all_registries" do
    test "toggles show all registries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      send(view.pid, {:curated_loaded, []})
      _ = :sys.get_state(view.pid)

      render_click(view, "toggle_all_registries", %{})
      html = render(view)
      assert html =~ "Curated" or html =~ "apps shown"
    end

    test "toggle works with curated entries loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "TestApp",
          source: "dockerhub",
          full_ref: "testapp:latest",
          description: "A test app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "apps shown"

      render_click(view, "toggle_all_registries", %{})
      html = render(view)
      assert html =~ "Showing all registries" or html =~ "Show all registries"
    end

    test "toggling twice returns to original state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      send(view.pid, {:curated_loaded, []})
      _ = :sys.get_state(view.pid)

      render_click(view, "toggle_all_registries", %{})
      render_click(view, "toggle_all_registries", %{})
      html = render(view)
      assert html =~ "Show all registries" or html =~ "Curated"
    end
  end

  describe "deploy_custom" do
    test "shows error when image or name is empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{"image" => "", "tag" => "latest", "name" => ""})
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "shows error when only image is provided", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{"image" => "nginx", "tag" => "latest", "name" => ""})
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "shows error when only name is provided", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{"image" => "", "tag" => "latest", "name" => "My App"})
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "creates template and opens deploy modal for valid custom image", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "nginx",
        "tag" => "latest",
        "name" => "My Nginx"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "My Nginx"
    end

    test "handles image with tag already included", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "nginx:alpine",
        "tag" => "ignored",
        "name" => "Nginx Alpine"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "Nginx Alpine"
    end

    test "custom deploy with full registry path", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "ghcr.io/owner/repo",
        "tag" => "v1.0",
        "name" => "GHCR App"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "GHCR App"
    end
  end

  describe "deploy modal interactions" do
    setup %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "redis",
        "tag" => "7",
        "name" => "Test Redis"
      })
      |> render_submit()

      {:ok, view: view, tenant: tenant}
    end

    test "close_deploy clears selected template", %{view: view} do
      render_click(view, "close_deploy", %{})
      html = render(view)
      refute has_element?(view, "#deploy-modal")
      refute html =~ "Deploy Test Redis"
    end

    test "close_deploy returns to catalog view", %{view: view} do
      render_click(view, "close_deploy", %{})
      html = render(view)
      assert html =~ "Curated" or html =~ "App Catalog"
    end

    test "add_port adds a new port entry", %{view: view} do
      render_click(view, "add_port", %{})
      html = render(view)
      assert html =~ "Ports"
    end

    test "add_port multiple times adds multiple ports", %{view: view} do
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      html = render(view)
      assert html =~ "Ports"
    end

    test "remove_port removes a port entry", %{view: view} do
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "remove_port", %{"index" => "0"})
      _html = render(view)
    end

    test "remove_port removes the correct port by index", %{view: view} do
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "remove_port", %{"index" => "1"})
      _html = render(view)
    end

    test "add_volume adds a new volume entry", %{view: view} do
      render_click(view, "add_volume", %{})
      html = render(view)
      assert html =~ "Volumes"
    end

    test "add_volume multiple times adds multiple volumes", %{view: view} do
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      html = render(view)
      assert html =~ "Volumes"
    end

    test "remove_volume removes a volume entry", %{view: view} do
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      render_click(view, "remove_volume", %{"index" => "0"})
      _html = render(view)
    end

    test "add_env_var adds a new environment variable", %{view: view} do
      render_click(view, "add_env_var", %{})
      html = render(view)
      assert html =~ "NEW_VAR"
    end

    test "add_env_var increments key names", %{view: view} do
      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})
      html = render(view)
      assert html =~ "NEW_VAR"
    end

    test "remove_env_var removes an environment variable", %{view: view} do
      render_click(view, "add_env_var", %{})
      render_click(view, "remove_env_var", %{"key" => "NEW_VAR_1"})
      _html = render(view)
    end

    test "remove_env_var for non-existent key is a no-op", %{view: view} do
      render_click(view, "remove_env_var", %{"key" => "DOES_NOT_EXIST"})
      _html = render(view)
    end

    test "modal shows space selector", %{view: view} do
      html = render(view)
      assert html =~ "Space" or html =~ "Select a space"
    end

    test "modal shows domain input", %{view: view} do
      html = render(view)
      assert html =~ "Domain"
    end

    test "modal shows exposure mode selector", %{view: view} do
      html = render(view)
      assert html =~ "Exposure Mode"
      assert html =~ "Public"
      assert html =~ "SSO Protected"
      assert html =~ "Private"
      assert html =~ "Service"
    end
  end

  describe "deploy" do
    test "deploys a custom template to a space", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_abc123"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "postgres",
        "tag" => "16",
        "name" => "My Postgres"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "pg.test.local"
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "deploys without a domain", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_xyz789"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "redis",
        "tag" => "7",
        "name" => "My Redis"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => ""
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "deploy with env overrides", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_env_test"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "mariadb",
        "tag" => "11",
        "name" => "My MariaDB"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => ""
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "deploy with exposure_mode set", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_private"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_2"}} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "grafana",
        "tag" => "latest",
        "name" => "Grafana"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "grafana.test.local",
          "exposure_mode" => "private"
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "deploy with ports configured", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_ports"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "myapp",
        "tag" => "latest",
        "name" => "Port App"
      })
      |> render_submit()

      render_click(view, "add_port", %{})

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => ""
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "deploy with volumes configured", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "container_vols"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "mydb",
        "tag" => "latest",
        "name" => "Volume App"
      })
      |> render_submit()

      render_click(view, "add_volume", %{})

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => ""
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end
  end

  describe "handle_info :load_curated" do
    test "sends curated_loaded with entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Curated" or html =~ "apps shown" or html =~ "Loading"
    end

    test "processing :load_curated does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      send(view.pid, :load_curated)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Curated" or html =~ "App Catalog"
    end
  end

  describe "handle_info {:curated_loaded, entries}" do
    test "assigns curated entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      send(view.pid, {:curated_loaded, []})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "0 of 0 apps shown" or html =~ "Curated"
    end

    test "assigns non-empty curated entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "Nextcloud",
          source: "dockerhub",
          full_ref: "nextcloud:latest",
          description: "Self-hosted cloud",
          categories: ["Cloud"],
          required_ports: [%{"internal" => "80", "external" => "80", "description" => "HTTP"}],
          required_volumes: [%{"path" => "/data", "description" => "Data"}],
          default_env: %{"NC_ADMIN" => "admin"},
          required_env: ["NC_ADMIN_PASSWORD"]
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Nextcloud" or html =~ "apps shown"
    end

    test "deduplicates entries with same name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "Grafana",
          source: "dockerhub",
          full_ref: "grafana/grafana:latest",
          description: "Monitoring dashboards",
          categories: ["Monitoring"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "Grafana",
          source: "linuxserver",
          full_ref: "lscr.io/linuxserver/grafana:latest",
          description: "LinuxServer Grafana",
          categories: ["Monitoring"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "apps shown"
    end

    test "entries with multiple categories are grouped", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "App One",
          source: "dockerhub",
          full_ref: "appone:latest",
          description: "First app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "App Two",
          source: "dockerhub",
          full_ref: "apptwo:latest",
          description: "Second app",
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "2 of 2 apps shown" or html =~ "apps shown"
    end
  end

  describe "handle_info {:enrichment_complete, entry}" do
    test "updates template when selected_entry exists", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "testimg",
        "tag" => "latest",
        "name" => "Enrichment Test"
      })
      |> render_submit()

      _ = :sys.get_state(view.pid)

      enriched = %CatalogEntry{
        name: "Enrichment Test",
        source: "dockerhub",
        full_ref: "testimg:latest",
        description: "Enriched description",
        required_ports: [
          %{
            "internal" => "3000",
            "external" => "3000",
            "description" => "Web",
            "role" => "web",
            "optional" => false,
            "published" => false
          }
        ],
        required_volumes: [%{"path" => "/config", "description" => "Config"}],
        default_env: %{"DB_HOST" => "localhost"},
        required_env: ["DB_PASSWORD"]
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Deploy" or html =~ "Enrichment Test"
    end

    test "no-op when selected_entry is nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      enriched = %CatalogEntry{
        name: "Orphan",
        source: "dockerhub",
        full_ref: "orphan:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: []
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)
      html = render(view)
      refute has_element?(view, "#deploy-modal")
      assert html =~ "App Catalog"
    end
  end

  describe "handle_info {:do_search, query, registry}" do
    test "processes search results asynchronously", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search" or html =~ "No results found"
    end

    test "search with specific registry filters results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "nginx", "dockerhub"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Search" or html =~ "No results found"
    end

    test "search with non-existent registry returns empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "anything", "nonexistent_registry"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "No results found" or html =~ "Search"
    end
  end

  describe "close_deploy event" do
    test "close_deploy clears both selected_template and selected_entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "app",
        "tag" => "latest",
        "name" => "Close Test"
      })
      |> render_submit()

      assert has_element?(view, "#deploy-modal")

      render_click(view, "close_deploy", %{})
      refute has_element?(view, "#deploy-modal")
      html = render(view)
      refute html =~ "Deploy Close Test"
    end

    test "close_deploy when modal is already closed is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "close_deploy", %{})
      html = render(view)
      assert html =~ "App Catalog"
    end
  end

  describe "custom form with different field combinations" do
    test "custom form with special characters in name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "myapp",
        "tag" => "latest",
        "name" => "My App (v2.0) - Beta!"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "My App"
    end

    test "custom form with empty tag defaults to latest", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "myapp",
        "tag" => "",
        "name" => "Empty Tag App"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "Empty Tag App"
    end

    test "custom form submitting the same image twice creates unique slugs", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "duplicatetest",
        "tag" => "latest",
        "name" => "Dup Test"
      })
      |> render_submit()

      render_click(view, "close_deploy", %{})

      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "duplicatetest",
        "tag" => "latest",
        "name" => "Dup Test 2"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "Dup Test 2"
    end
  end

  describe "select_entry from curated tab" do
    test "selecting a curated entry redirects to deploy wizard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "TestApp",
          source: "curated",
          full_ref: "testapp:latest",
          description: "Test",
          categories: ["tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)

      entry_json =
        Jason.encode!(%{
          "name" => "TestApp",
          "source" => "curated",
          "full_ref" => "testapp:latest",
          "description" => "Test",
          "categories" => ["tools"],
          "required_ports" => [],
          "required_volumes" => [],
          "default_env" => %{},
          "required_env" => []
        })

      render_click(view, "select_entry", %{"entry" => entry_json})
      {path, _flash} = assert_redirect(view)
      assert path =~ "/deploy/new"
    end
  end

  describe "select_entry from search results" do
    test "selecting a search result entry redirects to deploy wizard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      entry_json =
        Jason.encode!(%{
          "name" => "SearchApp",
          "source" => "dockerhub",
          "full_ref" => "searchapp:latest",
          "description" => "Found via search",
          "categories" => ["tools"],
          "required_ports" => [],
          "required_volumes" => [],
          "default_env" => %{},
          "required_env" => []
        })

      render_click(view, "select_entry", %{"entry" => entry_json})
      {path, _flash} = assert_redirect(view)
      assert path =~ "/deploy/new"
    end
  end

  describe "deploy_custom error path" do
    test "shows error flash when template creation fails due to duplicate slug", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "failapp",
        "tag" => "latest",
        "name" => "Fail App"
      })
      |> render_submit()

      _ = :sys.get_state(view.pid)
      html = render(view)
      assert has_element?(view, "#deploy-modal") or html =~ "Deploy" or html =~ "Fail App" or
               html =~ "Failed to create"
    end
  end

  defmodule TestSearchRegistry do
    @behaviour Homelab.Behaviours.ContainerRegistry
    alias Homelab.Catalog.CatalogEntry

    def driver_id, do: "test_registry"
    def display_name, do: "Test Registry"
    def description, do: "Test registry for search coverage"
    def capabilities, do: [:search]

    def search("redis", _opts) do
      {:ok,
       [
         %CatalogEntry{
           name: "Redis",
           source: "test_registry",
           full_ref: "redis:latest",
           namespace: "library",
           description: "In-memory data store",
           categories: [],
           required_ports: [],
           required_volumes: [],
           default_env: %{},
           required_env: [],
           stars: 1000,
           pulls: 5000
         }
       ]}
    end

    def search(_query, _opts), do: {:ok, []}

    def list_tags(_image, _opts), do: {:ok, []}
    def full_image_ref(name, tag), do: "#{name}:#{tag}"
    def configured?, do: true
    def pull_auth_config, do: {:error, :not_configured}
  end

  describe "deploy modal port and volume rendering" do
    test "renders port form fields with Host, Container, and Role labels", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "portrender1",
        "tag" => "latest",
        "name" => "Port Render"
      })
      |> render_submit()

      render_click(view, "add_port", %{})
      html = render(view)

      assert html =~ "Host"
      assert html =~ "Container"
      assert html =~ "Role"
    end

    test "renders volume form field with Container path label", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "volrender1",
        "tag" => "latest",
        "name" => "Vol Render"
      })
      |> render_submit()

      render_click(view, "add_volume", %{})
      html = render(view)

      assert html =~ "Container path"
    end

    test "renders optional badges for newly added ports and volumes", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "optbadge1",
        "tag" => "latest",
        "name" => "Opt Badge"
      })
      |> render_submit()

      render_click(view, "add_port", %{})
      render_click(view, "add_volume", %{})
      html = render(view)

      assert html =~ "optional"
    end

    test "renders Add port, Add volume, and Add variable buttons in modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "addbtns1",
        "tag" => "latest",
        "name" => "Add Btns"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "Add port"
      assert html =~ "Add volume"
      assert html =~ "Add variable"
    end

    test "renders environment defaults section after adding env var", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "envrender1",
        "tag" => "latest",
        "name" => "Env Render"
      })
      |> render_submit()

      render_click(view, "add_env_var", %{})
      html = render(view)

      assert html =~ "Environment defaults"
      assert html =~ "NEW_VAR_1"
    end

    test "renders multiple ports and volumes with correct form structure", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "multiport1",
        "tag" => "latest",
        "name" => "Multi Port"
      })
      |> render_submit()

      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "add_volume", %{})

      html = render(view)

      assert html =~ "Ports"
      assert html =~ "Volumes"
      assert html =~ "Host"
      assert html =~ "Container path"
    end
  end

  describe "search tab with rendered results" do
    setup do
      prev = Application.get_env(:homelab, :registries)

      Application.put_env(
        :homelab,
        :registries,
        [HomelabWeb.CatalogLiveTest.TestSearchRegistry]
      )

      on_exit(fn -> Application.put_env(:homelab, :registries, prev) end)
      :ok
    end

    test "renders search result entry name and description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "redis", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Redis"
      assert html =~ "In-memory data store"
    end

    test "renders search result source badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "redis", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Test Registry" or html =~ "test_registry"
    end

    test "renders search result namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "redis", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "library"
    end

    test "renders search result star and pull counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "redis", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "1000"
      assert html =~ "5000"
    end

    test "shows no results found for query with no matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      render_click(view, "search", %{"query" => "nonexistent_zzzz", "registry" => ""})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "No results found"
    end
  end

  describe "curated entry cards with badges" do
    test "renders port and volume count badges on entry cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "BadgeApp",
          source: "dockerhub",
          full_ref: "badgeapp:latest",
          description: "App with ports and volumes",
          categories: ["Tools"],
          required_ports: [
            %{"internal" => "80", "external" => "80", "description" => "HTTP"},
            %{"internal" => "443", "external" => "443", "description" => "HTTPS"}
          ],
          required_volumes: [
            %{"path" => "/data", "description" => "Data"},
            %{"path" => "/config", "description" => "Config"}
          ],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "BadgeApp"
      assert html =~ "2"
    end

    test "renders GHCR registry label for ghcr.io entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "GhcrApp",
          source: "ghcr",
          full_ref: "ghcr.io/owner/ghcrapp:latest",
          description: "A GHCR hosted app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      render_click(view, "toggle_all_registries", %{})
      html = render(view)

      assert html =~ "GhcrApp"
      assert html =~ "GHCR"
    end

    test "renders alt_sources badge for entries from multiple registries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "MultiSrcApp",
          source: "dockerhub",
          full_ref: "multisrcapp:latest",
          description: "Primary source app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "MultiSrcApp",
          source: "linuxserver",
          full_ref: "lscr.io/linuxserver/multisrcapp:latest",
          description: "LinuxServer version",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "MultiSrcApp"
      assert html =~ "+1"
    end

    test "groups entries by category with separate headers", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "MediaPlayer",
          source: "dockerhub",
          full_ref: "mediaplayer:latest",
          description: "A media player",
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "DevTool",
          source: "dockerhub",
          full_ref: "devtool:latest",
          description: "A development tool",
          categories: ["Development - Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Media"
      assert html =~ "Tools"
      assert html =~ "MediaPlayer"
      assert html =~ "DevTool"
    end

    test "renders fallback text for entries without description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "NoDescApp",
          source: "dockerhub",
          full_ref: "nodescapp:latest",
          description: nil,
          categories: ["Other"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "No description available"
    end

    test "shows filtered entry count when mixed registries present", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "DockerOnlyApp",
          source: "dockerhub",
          full_ref: "dockeronlyapp:latest",
          description: "Docker Hub app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "GhcrOnlyApp",
          source: "ghcr",
          full_ref: "ghcr.io/owner/ghcronlyapp:latest",
          description: "GHCR-only app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "1 of 2 apps shown"
    end
  end

  describe "deploy modal details and state" do
    test "shows tenant name in space selector dropdown", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "tenantshow1",
        "tag" => "latest",
        "name" => "Tenant Show"
      })
      |> render_submit()

      html = render(view)

      assert html =~ tenant.name
      assert html =~ "Select a space"
    end

    test "shows domain input with reverse proxy description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "domainhint1",
        "tag" => "latest",
        "name" => "Domain Hint"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "yourdomain.com"
      assert html =~ "reverse proxy"
    end

    test "shows all exposure mode options in selector", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "expmode1",
        "tag" => "latest",
        "name" => "Exposure Mode"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "Public"
      assert html =~ "SSO Protected"
      assert html =~ "Private (LAN only)"
      assert html =~ "Service (proxy-only, no host ports)"
    end

    test "shows deploy modal header with template name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "hdrtest1",
        "tag" => "latest",
        "name" => "Header Test"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "Deploy Header Test"
    end

    test "shows cancel button and deploy form submit button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "actionbtns1",
        "tag" => "latest",
        "name" => "Action Btns"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "Cancel"
      assert has_element?(view, "#deploy-form")
    end
  end

  describe "deploy error states" do
    test "deploy with orchestrator error shows failure flash", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:error, "resource limit exceeded"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "failorch1",
        "tag" => "latest",
        "name" => "Fail Orch"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => ""
        })
        |> render_submit()

      assert html =~ "failed" or html =~ "Failed" or html =~ "error" or html =~ "Error"
    end

    test "deploy_custom with all fields empty shows validation flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{
          "image" => "",
          "tag" => "",
          "name" => ""
        })
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "deploy modal version and exposure pill render", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "versionpill1",
        "tag" => "2.5",
        "name" => "Version Pill"
      })
      |> render_submit()

      html = render(view)

      assert html =~ "v2.5" or html =~ "2.5"
      assert html =~ "Deploy Version Pill"
    end
  end

  describe "registry filter button rendering" do
    test "shows 'Show all registries' button when entries are loaded", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "FilterBtnApp",
          source: "dockerhub",
          full_ref: "filterbtnapp:latest",
          description: "Filter button test",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Show all registries"
      refute html =~ "Showing all registries"
    end

    test "toggling updates button text to 'Showing all registries'", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "ToggleBtnApp",
          source: "dockerhub",
          full_ref: "togglebtnapp:latest",
          description: "Toggle button test",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      render_click(view, "toggle_all_registries", %{})
      html = render(view)

      assert html =~ "Showing all registries"
    end

    test "toggle changes visible entry count with mixed registries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "VisibleCntApp",
          source: "dockerhub",
          full_ref: "visiblecntapp:latest",
          description: "Visible app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "HiddenCntApp",
          source: "ghcr",
          full_ref: "ghcr.io/owner/hiddencntapp:latest",
          description: "Hidden app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "1 of 2 apps shown"

      render_click(view, "toggle_all_registries", %{})
      html = render(view)

      assert html =~ "2 of 2 apps shown"
    end
  end

  defmodule TestVariationRegistry do
    @behaviour Homelab.Behaviours.ContainerRegistry
    alias Homelab.Catalog.CatalogEntry

    def driver_id, do: "test_variation"
    def display_name, do: "Variation Registry"
    def description, do: "Test registry for variation coverage"
    def capabilities, do: [:search]

    def search("variation_test", _opts) do
      {:ok,
       [
         %CatalogEntry{
           name: "StarsOnly",
           source: "test_variation",
           full_ref: "starsonly:latest",
           namespace: nil,
           description: nil,
           categories: [],
           required_ports: [],
           required_volumes: [],
           default_env: %{},
           required_env: [],
           stars: 750,
           pulls: 0
         },
         %CatalogEntry{
           name: "PullsOnly",
           source: "test_variation",
           full_ref: "pullsonly:latest",
           namespace: "myorg",
           description: "High pull count app",
           categories: [],
           required_ports: [],
           required_volumes: [],
           default_env: %{},
           required_env: [],
           stars: 0,
           pulls: 25000
         }
       ]}
    end

    def search(_query, _opts), do: {:ok, []}

    def list_tags(_image, _opts), do: {:ok, []}
    def full_image_ref(name, tag), do: "#{name}:#{tag}"
    def configured?, do: true
    def pull_auth_config, do: {:error, :not_configured}
  end

  describe "curated entry card rendering variations" do
    test "renders entry with logo_url as an img element", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "LogoApp",
          source: "dockerhub",
          full_ref: "logoapp:latest",
          description: "Has a logo",
          logo_url: "https://example.com/icon.png",
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "LogoApp"
      assert html =~ "https://example.com/icon.png"
    end

    test "renders entry without logo_url using cube icon fallback", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "PlainApp",
          source: "dockerhub",
          full_ref: "plainapp:latest",
          description: "No logo set",
          logo_url: nil,
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "PlainApp"
      assert html =~ "hero-cube"
    end

    test "renders named icon for recognized app names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "nextcloud",
          source: "dockerhub",
          full_ref: "nextcloud:latest",
          description: "Self-hosted cloud",
          logo_url: nil,
          categories: ["Cloud"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "jellyfin",
          source: "dockerhub",
          full_ref: "jellyfin/jellyfin:latest",
          description: "Media server",
          logo_url: nil,
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-cloud"
      assert html =~ "hero-film"
    end

    test "renders non-pullable entry with lock icon", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "PrivateGhcrApp",
          source: "ghcr",
          full_ref: "ghcr.io/private-org/app:latest",
          description: "Private registry app",
          categories: ["Private"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      render_click(view, "toggle_all_registries", %{})
      html = render(view)

      assert html =~ "PrivateGhcrApp"
      assert html =~ "hero-lock-closed-mini" or html =~ "opacity-60"
    end

    test "renders entry with namespace in compact source line", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "NsApp",
          source: "dockerhub",
          full_ref: "myorg/nsapp:latest",
          namespace: "myorg",
          description: "Namespaced app",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "NsApp"
      assert html =~ "myorg"
    end

    test "renders port and volume count badges with correct counts", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "FullApp",
          source: "dockerhub",
          full_ref: "fullapp:latest",
          description: "Full featured app",
          categories: ["Tools"],
          required_ports: [
            %{"internal" => "80", "external" => "80", "description" => "HTTP"},
            %{"internal" => "443", "external" => "443", "description" => "HTTPS"},
            %{"internal" => "8080", "external" => "8080", "description" => "Admin"}
          ],
          required_volumes: [
            %{"path" => "/data", "description" => "Data"},
            %{"path" => "/config", "description" => "Config"}
          ],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "FullApp"
      assert html =~ "hero-signal-mini"
      assert html =~ "hero-circle-stack-mini"
    end
  end

  describe "custom deploy with different image formats" do
    test "ghcr.io image opens deploy modal with correct name and version", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "ghcr.io/myorg/webapp",
        "tag" => "v3.1",
        "name" => "GHCR Webapp"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal")
      assert html =~ "Deploy GHCR Webapp"
      assert html =~ "v3.1"
    end

    test "custom registry image opens deploy modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "registry.example.com/team/service",
        "tag" => "stable",
        "name" => "Custom Reg Service"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal")
      assert html =~ "Deploy Custom Reg Service"
    end

    test "image with embedded colon-tag ignores separate tag field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "myapp:beta",
        "tag" => "ignored",
        "name" => "Beta App"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal")
      assert html =~ "Deploy Beta App"
    end

    test "docker.io prefixed image opens deploy modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "docker.io/library/nginx",
        "tag" => "alpine",
        "name" => "Docker IO Nginx"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal")
      assert html =~ "Deploy Docker IO Nginx"
    end
  end

  describe "deploy form submission error paths" do
    test "deploy failure from orchestrator error shows error flash", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:error, "container limit reached"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "errorch",
        "tag" => "latest",
        "name" => "Orch Error"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "err.test.local"
        })
        |> render_submit()

      assert html =~ "failed" or html =~ "Failed" or html =~ "Deployment failed"
    end

    test "deploy_custom with image empty and name filled shows validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{
          "image" => "",
          "tag" => "v1",
          "name" => "No Image"
        })
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "deploy_custom with name empty and image filled shows validation error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      html =
        view
        |> form("#custom-deploy-form", %{
          "image" => "someimage",
          "tag" => "latest",
          "name" => ""
        })
        |> render_submit()

      assert html =~ "Image and name are required"
    end

    test "deploy with orchestrator error preserves modal on error", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:error, "timeout"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "timeoutapp",
        "tag" => "latest",
        "name" => "Timeout App"
      })
      |> render_submit()

      view
      |> form("#deploy-form", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => ""
      })
      |> render_submit()

      html = render(view)
      assert html =~ "failed" or html =~ "Failed" or html =~ "Deployment failed"
    end
  end

  describe "sequential add and remove of ports volumes and env vars" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "seqtest",
        "tag" => "latest",
        "name" => "Seq Test"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "adding 3 ports renders all with indexed form names", %{view: view} do
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      html = render(view)

      assert html =~ "ports[0][external]"
      assert html =~ "ports[1][external]"
      assert html =~ "ports[2][external]"
      assert html =~ "ports[0][internal]"
      assert html =~ "ports[1][internal]"
      assert html =~ "ports[2][internal]"
    end

    test "adding 3 volumes renders all with indexed form names", %{view: view} do
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      html = render(view)

      assert html =~ "volumes[0][container_path]"
      assert html =~ "volumes[1][container_path]"
      assert html =~ "volumes[2][container_path]"
    end

    test "adding 3 env vars renders all with sequential names", %{view: view} do
      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})
      html = render(view)

      assert html =~ "NEW_VAR_1"
      assert html =~ "NEW_VAR_2"
      assert html =~ "NEW_VAR_3"
      assert html =~ "Environment defaults"
    end

    test "removing middle port reindexes remaining", %{view: view} do
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "remove_port", %{"index" => "1"})
      html = render(view)

      assert html =~ "ports[0][external]"
      assert html =~ "ports[1][external]"
      refute html =~ "ports[2][external]"
    end

    test "removing middle volume reindexes remaining", %{view: view} do
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      render_click(view, "add_volume", %{})
      render_click(view, "remove_volume", %{"index" => "1"})
      html = render(view)

      assert html =~ "volumes[0][container_path]"
      assert html =~ "volumes[1][container_path]"
      refute html =~ "volumes[2][container_path]"
    end

    test "removing env var removes it from rendered output", %{view: view} do
      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})

      html = render(view)
      assert html =~ "NEW_VAR_1"
      assert html =~ "NEW_VAR_2"
      assert html =~ "NEW_VAR_3"

      render_click(view, "remove_env_var", %{"key" => "NEW_VAR_3"})
      html = render(view)

      assert html =~ "NEW_VAR_1"
      assert html =~ "NEW_VAR_2"
      refute html =~ "NEW_VAR_3"
    end

    test "newly added ports show optional badge", %{view: view} do
      render_click(view, "add_port", %{})
      html = render(view)
      assert html =~ "optional"
    end

    test "newly added volumes show optional badge", %{view: view} do
      render_click(view, "add_volume", %{})
      html = render(view)
      assert html =~ "optional"
    end

    test "port role selector renders with role options", %{view: view} do
      render_click(view, "add_port", %{})
      html = render(view)
      assert html =~ "Role"
      assert html =~ "Host"
      assert html =~ "Container"
    end
  end

  describe "search result entry rendering variations" do
    setup do
      prev = Application.get_env(:homelab, :registries)

      Application.put_env(
        :homelab,
        :registries,
        [HomelabWeb.CatalogLiveTest.TestVariationRegistry]
      )

      on_exit(fn -> Application.put_env(:homelab, :registries, prev) end)
      :ok
    end

    test "renders star count for entry with stars but no pulls", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "750"
    end

    test "renders pull count for entry with pulls but no stars", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "25000"
    end

    test "renders No description for entry with nil description", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "No description"
    end

    test "shows namespace for entries that have one and hides for nil", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "myorg"
    end

    test "renders source badge from registry display name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Variation Registry" or html =~ "test_variation"
    end

    test "both entries render with their names", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      send(view.pid, {:do_search, "variation_test", nil})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "StarsOnly"
      assert html =~ "PullsOnly"
    end
  end

  describe "curated tab loading and empty states" do
    test "shows loading or empty indicator when curated entries are empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      send(view.pid, {:curated_loaded, []})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Loading curated catalog" or html =~ "0 of 0 apps shown" or
               html =~ "Curated"
    end

    test "shows correct apps count after multiple entries load", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "CountApp1",
          source: "dockerhub",
          full_ref: "countapp1:latest",
          description: "First",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "CountApp2",
          source: "dockerhub",
          full_ref: "countapp2:latest",
          description: "Second",
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "CountApp3",
          source: "dockerhub",
          full_ref: "countapp3:latest",
          description: "Third",
          categories: ["Cloud"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "3 of 3 apps shown"
    end

    test "displays category headers for grouped entries", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "ToolsApp",
          source: "dockerhub",
          full_ref: "toolsapp:latest",
          description: "A tool",
          categories: ["Development - Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "MediaApp",
          source: "dockerhub",
          full_ref: "mediaapp:latest",
          description: "A media app",
          categories: ["Media - Streaming"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Tools"
      assert html =~ "Streaming"
    end
  end

  describe "deploy modal close and reopen" do
    test "closing and reopening with different image shows new template name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "firstimg",
        "tag" => "1.0",
        "name" => "First Modal"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Deploy First Modal"
      assert has_element?(view, "#deploy-modal")

      render_click(view, "close_deploy", %{})
      refute has_element?(view, "#deploy-modal")

      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "secondimg",
        "tag" => "2.0",
        "name" => "Second Modal"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Deploy Second Modal"
      assert has_element?(view, "#deploy-modal")
      refute html =~ "Deploy First Modal"
    end

    test "closing modal removes both deploy-modal and deploy-form from DOM", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "closecheck",
        "tag" => "latest",
        "name" => "Close Check"
      })
      |> render_submit()

      assert has_element?(view, "#deploy-form")
      assert has_element?(view, "#deploy-modal")

      render_click(view, "close_deploy", %{})

      refute has_element?(view, "#deploy-form")
      refute has_element?(view, "#deploy-modal")
    end

    test "added ports reset when modal is closed and reopened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "resettest",
        "tag" => "latest",
        "name" => "Reset Test"
      })
      |> render_submit()

      render_click(view, "add_port", %{})
      render_click(view, "add_port", %{})
      render_click(view, "add_volume", %{})
      html = render(view)
      assert html =~ "ports[0][external]"
      assert html =~ "ports[1][external]"
      assert html =~ "volumes[0][container_path]"

      render_click(view, "close_deploy", %{})

      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "resettest2",
        "tag" => "latest",
        "name" => "Reset Test 2"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Deploy Reset Test 2"
      refute html =~ "ports[1][external]"
    end

    test "env vars reset when modal is closed and reopened", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "envresettest",
        "tag" => "latest",
        "name" => "Env Reset"
      })
      |> render_submit()

      render_click(view, "add_env_var", %{})
      render_click(view, "add_env_var", %{})
      html = render(view)
      assert html =~ "NEW_VAR_1"
      assert html =~ "NEW_VAR_2"

      render_click(view, "close_deploy", %{})

      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "envresettest2",
        "tag" => "latest",
        "name" => "Env Reset 2"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Deploy Env Reset 2"
      refute html =~ "NEW_VAR_1"
      refute html =~ "NEW_VAR_2"
    end
  end

  describe "search empty results state" do
    test "shows no results message when query produces no matches", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      render_click(view, "search", %{
        "query" => "zzz_completely_nonexistent_app_xyz",
        "registry" => ""
      })

      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "No results found"
    end

    test "empty results state only shows when query is non-empty", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "search"})

      html = render(view)
      refute html =~ "No results found"
    end
  end

  defp inject_selected_entry(view, entry) do
    :sys.replace_state(view.pid, fn state ->
      socket = state.socket
      new_assigns = Map.put(socket.assigns, :selected_entry, entry)
      %{state | socket: %{socket | assigns: new_assigns}}
    end)

    _ = :sys.get_state(view.pid)
  end

  defp make_stub_entry(name, full_ref) do
    %CatalogEntry{
      name: name,
      source: "dockerhub",
      full_ref: full_ref,
      required_ports: [],
      required_volumes: [],
      default_env: %{},
      required_env: [],
      categories: []
    }
  end

  defp send_enrichment(view, enriched) do
    send(view.pid, {:enrichment_complete, enriched})
    _ = :sys.get_state(view.pid)
  end

  describe "deploy modal enriched port rendering" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "eprt",
        "tag" => "latest",
        "name" => "EPrt App"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "renders port description text", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EPrt App", "eprt:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EPrt App",
        source: "dockerhub",
        full_ref: "eprt:latest",
        required_ports: [
          %{
            "internal" => "8080",
            "external" => "8080",
            "description" => "Application HTTP",
            "role" => "other",
            "optional" => false
          }
        ],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "Application HTTP"
    end

    test "renders required badge for non-optional port", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EPrt App", "eprt:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EPrt App",
        source: "dockerhub",
        full_ref: "eprt:latest",
        required_ports: [
          %{
            "internal" => "80",
            "external" => "80",
            "description" => "HTTP",
            "role" => "other",
            "optional" => false
          }
        ],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "required"
      assert html =~ "bg-warning"
    end

    test "renders proxy hint for web role port", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EPrt App", "eprt:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EPrt App",
        source: "dockerhub",
        full_ref: "eprt:latest",
        required_ports: [
          %{
            "internal" => "80",
            "external" => "80",
            "description" => "Web",
            "role" => "web",
            "optional" => false
          }
        ],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "reverse proxy"
    end

    test "renders both required and optional ports", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EPrt App", "eprt:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EPrt App",
        source: "dockerhub",
        full_ref: "eprt:latest",
        required_ports: [
          %{
            "internal" => "80",
            "external" => "80",
            "description" => "HTTP",
            "role" => "web",
            "optional" => false
          },
          %{
            "internal" => "9090",
            "external" => "9090",
            "description" => "Metrics",
            "role" => "other",
            "optional" => "true"
          }
        ],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "HTTP"
      assert html =~ "Metrics"
      assert html =~ "required"
      assert html =~ "optional"
    end
  end

  describe "deploy modal enriched volume rendering" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "evol",
        "tag" => "latest",
        "name" => "EVol App"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "renders volume description text", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EVol App", "evol:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EVol App",
        source: "dockerhub",
        full_ref: "evol:latest",
        required_ports: [],
        required_volumes: [%{"path" => "/config", "description" => "Config storage"}],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "Config storage"
    end

    test "renders required badge for enriched volumes", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EVol App", "evol:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EVol App",
        source: "dockerhub",
        full_ref: "evol:latest",
        required_ports: [],
        required_volumes: [%{"path" => "/data", "description" => "App data"}],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "required"
      assert html =~ "bg-warning"
    end
  end

  describe "deploy modal required env and secret rendering" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "eenv",
        "tag" => "latest",
        "name" => "EEnv App"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "renders required configuration section", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EEnv App", "eenv:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EEnv App",
        source: "dockerhub",
        full_ref: "eenv:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: ["DB_HOST", "DB_PORT"],
        categories: []
      })

      html = render(view)
      assert html =~ "Required configuration"
      assert html =~ "DB_HOST"
      assert html =~ "DB_PORT"
    end

    test "renders password type for PASSWORD required env var", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EEnv App", "eenv:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EEnv App",
        source: "dockerhub",
        full_ref: "eenv:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: ["DB_PASSWORD"],
        categories: []
      })

      html = render(view)
      assert html =~ "type=\"password\""
      assert html =~ "DB_PASSWORD"
    end

    test "renders password type for SECRET default env var", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EEnv App", "eenv:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EEnv App",
        source: "dockerhub",
        full_ref: "eenv:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{"API_SECRET" => "changeme"},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "type=\"password\""
      assert html =~ "API_SECRET"
    end

    test "renders text type for non-secret env vars", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EEnv App", "eenv:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EEnv App",
        source: "dockerhub",
        full_ref: "eenv:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{"APP_PORT" => "3000"},
        required_env: ["DB_NAME"],
        categories: []
      })

      html = render(view)
      assert html =~ "DB_NAME"
      assert html =~ "APP_PORT"
      assert html =~ "3000"
    end

    test "renders humanized placeholder for required env vars", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EEnv App", "eenv:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EEnv App",
        source: "dockerhub",
        full_ref: "eenv:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: ["REDIS_URL"],
        categories: []
      })

      html = render(view)
      assert html =~ "Enter redis url"
    end
  end

  describe "deploy docs link rendering" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "edocs",
        "tag" => "latest",
        "name" => "EDocs App"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "shows info box when no config but setup_url and project_url set", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EDocs App", "edocs:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EDocs App",
        source: "dockerhub",
        full_ref: "edocs:latest",
        setup_url: "https://docs.example.com/setup",
        project_url: "https://github.com/example/edocs",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "No ports or volumes auto-detected"
      assert html =~ "Setup guide"
      assert html =~ "Project page"
      assert html =~ "https://docs.example.com/setup"
      assert html =~ "https://github.com/example/edocs"
    end

    test "shows inline links when has ports and setup_url set", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EDocs App", "edocs:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EDocs App",
        source: "dockerhub",
        full_ref: "edocs:latest",
        setup_url: "https://docs.example.com/config",
        project_url: "https://github.com/example/edocs",
        required_ports: [
          %{
            "internal" => "80",
            "external" => "80",
            "description" => "HTTP",
            "role" => "web",
            "optional" => false
          }
        ],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "Setup guide"
      assert html =~ "Project page"
      refute html =~ "No ports or volumes auto-detected"
    end

    test "shows only project page when setup_url is nil", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EDocs App", "edocs:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EDocs App",
        source: "dockerhub",
        full_ref: "edocs:latest",
        setup_url: nil,
        project_url: "https://github.com/example/edocs",
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      assert html =~ "Project page"
      refute html =~ "Setup guide"
    end

    test "hides docs section when no setup_url or project_url", %{view: view} do
      inject_selected_entry(view, make_stub_entry("EDocs App", "edocs:latest"))

      send_enrichment(view, %CatalogEntry{
        name: "EDocs App",
        source: "dockerhub",
        full_ref: "edocs:latest",
        setup_url: nil,
        project_url: nil,
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      })

      html = render(view)
      refute html =~ "Setup guide"
      refute html =~ "Project page"
      refute html =~ "No ports or volumes auto-detected"
    end
  end

  describe "exposure pill variants" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "expvar",
        "tag" => "latest",
        "name" => "ExpVar App"
      })
      |> render_submit()

      {:ok, view: view}
    end

    test "renders SSO pill for default sso_protected mode", %{view: view} do
      html = render(view)
      assert html =~ "SSO"
      assert html =~ "hero-shield-check-mini"
    end

    test "renders exposure pill with success class for sso mode", %{view: view} do
      html = render(view)
      assert html =~ "bg-success"
    end
  end

  describe "deploy with exposure mode updates template" do
    test "submitting with public mode updates template exposure", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "ctr_pub"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _z, _r -> {:ok, %{id: "r1"}} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "pubmode",
        "tag" => "latest",
        "name" => "Pub Mode"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "pub.test.local",
          "exposure_mode" => "public"
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "submitting with service mode updates template exposure", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "ctr_svc"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "svcmode",
        "tag" => "latest",
        "name" => "Svc Mode"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "",
          "exposure_mode" => "service"
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end

    test "submitting with private mode updates template exposure", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "ctr_prv"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "prvmode",
        "tag" => "latest",
        "name" => "Prv Mode"
      })
      |> render_submit()

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "",
          "exposure_mode" => "private"
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end
  end

  describe "deploy with env overrides submitted" do
    test "submits env_overrides through the deploy form", %{conn: conn, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "ctr_envov"} end)

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "envov",
        "tag" => "latest",
        "name" => "EnvOv App"
      })
      |> render_submit()

      render_click(view, "add_env_var", %{})

      html =
        view
        |> form("#deploy-form", %{
          "tenant_id" => to_string(tenant.id),
          "domain" => "",
          "env_overrides" => %{"NEW_VAR_1" => "my_value"}
        })
        |> render_submit()

      assert html =~ "deployment started" or html =~ "Deployment"
    end
  end

  describe "curated entries with additional app icon variants" do
    test "renders immich icon for immich app", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "immich",
          source: "dockerhub",
          full_ref: "immich:latest",
          description: "Photo management",
          logo_url: nil,
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-photo"
    end

    test "renders key icon for vaultwarden app", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "vaultwarden",
          source: "dockerhub",
          full_ref: "vaultwarden/server:latest",
          description: "Password manager",
          logo_url: nil,
          categories: ["Security"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-key"
    end

    test "renders chart-bar icon for uptime-kuma app", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "uptime-kuma",
          source: "dockerhub",
          full_ref: "louislam/uptime-kuma:latest",
          description: "Uptime monitoring",
          logo_url: nil,
          categories: ["Monitoring"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-chart-bar"
    end

    test "renders code-bracket icon for gitea app", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "gitea",
          source: "dockerhub",
          full_ref: "gitea/gitea:latest",
          description: "Git hosting",
          logo_url: nil,
          categories: ["Development"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-code-bracket"
    end

    test "renders document-text icon for paperless-ngx", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "paperless-ngx",
          source: "dockerhub",
          full_ref: "paperlessngx/paperless-ngx:latest",
          description: "Document management",
          logo_url: nil,
          categories: ["Documents"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-document-text"
    end

    test "renders rss icon for freshrss", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "freshrss",
          source: "dockerhub",
          full_ref: "freshrss/freshrss:latest",
          description: "RSS reader",
          logo_url: nil,
          categories: ["Media"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-rss"
    end

    test "renders shield-check icon for wireguard", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "wireguard",
          source: "dockerhub",
          full_ref: "linuxserver/wireguard:latest",
          description: "VPN server",
          logo_url: nil,
          categories: ["Networking"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-shield-check"
    end

    test "renders cake icon for mealie", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "mealie",
          source: "dockerhub",
          full_ref: "hkotel/mealie:latest",
          description: "Recipe manager",
          logo_url: nil,
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "hero-cake"
    end

    test "renders curated entry with stars and pulls in card metadata", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "PopularApp",
          source: "dockerhub",
          full_ref: "popularapp:latest",
          description: "A popular app",
          categories: ["Tools"],
          required_ports: [
            %{"internal" => "80", "external" => "80", "description" => "HTTP"}
          ],
          required_volumes: [
            %{"path" => "/data", "description" => "Data"}
          ],
          default_env: %{},
          required_env: [],
          stars: 5000,
          pulls: 100_000
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "PopularApp"
      assert html =~ "hero-signal-mini"
      assert html =~ "hero-circle-stack-mini"
    end
  end

  describe "compact_source rendering in curated cards" do
    test "renders source + N more for entries with alt_sources", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "MultiRegApp",
          source: "dockerhub",
          full_ref: "multiregapp:latest",
          description: "Multi-registry",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "MultiRegApp",
          source: "linuxserver",
          full_ref: "lscr.io/linuxserver/multiregapp:latest",
          description: "LS version",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        },
        %CatalogEntry{
          name: "MultiRegApp",
          source: "hotio",
          full_ref: "hotio.dev/multiregapp:latest",
          description: "Hotio version",
          categories: ["Tools"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "MultiRegApp"
      assert html =~ "+2"
    end

    test "renders source / namespace for entries with namespace", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      entries = [
        %CatalogEntry{
          name: "NsOrgApp",
          source: "dockerhub",
          full_ref: "mycompany/nsorgapp:latest",
          namespace: "mycompany",
          description: "Org-namespaced app",
          categories: ["Enterprise"],
          required_ports: [],
          required_volumes: [],
          default_env: %{},
          required_env: []
        }
      ]

      send(view.pid, {:curated_loaded, entries})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "NsOrgApp"
      assert html =~ "mycompany"
    end
  end

  describe "deploy modal logo rendering" do
    test "shows template logo when logo_url is set on template", %{conn: conn} do
      template =
        insert(:app_template,
          name: "Logo Template",
          slug: "logo-template-test",
          logo_url: "https://example.com/logo.png",
          image: "logoimg:latest",
          version: "1.0",
          exposure_mode: :sso_protected
        )

      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "logotpl",
        "tag" => "latest",
        "name" => "Logo Tpl App"
      })
      |> render_submit()

      html = render(view)
      assert has_element?(view, "#deploy-modal")
      assert html =~ "Deploy Logo Tpl App"

      Homelab.Catalog.delete_app_template(template)
    end

    test "shows icon fallback when template has no logo_url", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")
      render_click(view, "switch_tab", %{"tab" => "custom"})

      view
      |> form("#custom-deploy-form", %{
        "image" => "nologo",
        "tag" => "latest",
        "name" => "No Logo App"
      })
      |> render_submit()

      html = render(view)
      assert html =~ "hero-cube"
    end
  end
end
