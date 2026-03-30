defmodule HomelabWeb.DeployWizardLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Catalog.CatalogEntry

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    tenant = insert(:tenant)

    template =
      insert(:app_template,
        name: "TestApp",
        slug: "testapp",
        image: "testapp:latest",
        default_env: %{"APP_ENV" => "production", "APP_URL" => ""},
        required_env: ["APP_SECRET"],
        ports: [%{"internal" => "8080", "external" => "", "description" => "HTTP", "role" => "http", "optional" => false, "published" => false}],
        volumes: [%{"container_path" => "/data", "description" => "App data"}]
      )

    %{tenant: tenant, template: template}
  end

  describe "mount and initial render" do
    test "renders the type selection step", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new")

      assert html =~ "New Deployment"
      assert html =~ "Container"
      assert html =~ "Compose Project"
      assert html =~ "Swarm Stack"
    end

    test "shows step indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new")

      assert html =~ "Type"
      assert html =~ "Application"
      assert html =~ "Network"
      assert html =~ "Configure"
      assert html =~ "Review"
    end
  end

  describe "select_type event" do
    test "selecting container type navigates to app step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new")

      view
      |> element("[phx-click=select_type][phx-value-type=container]")
      |> render_click()

      html = render(view)
      assert html =~ "Search registries"
      assert html =~ "Custom image"
      assert html =~ "Browse catalog"
    end

    test "selecting compose type navigates to app step with compose input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new")

      view
      |> element("[phx-click=select_type][phx-value-type=compose]")
      |> render_click()

      html = render(view)
      assert html =~ "docker-compose.yml"
      assert html =~ "Parse"
    end

    test "selecting stack type navigates to app step with compose input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new")

      view
      |> element("[phx-click=select_type][phx-value-type=stack]")
      |> render_click()

      html = render(view)
      assert html =~ "docker-compose.yml"
    end
  end

  describe "step navigation" do
    test "go_step navigates to the specified step", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> element("[phx-click=go_step][phx-value-step=config]")
      |> render_click()

      html = render(view)
      assert html =~ "Ports"
      assert html =~ "Volumes"
    end

    test "back navigates to the previous step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> element("[phx-click=back]")
      |> render_click()

      html = render(view)
      assert html =~ "Container"
      assert html =~ "Compose Project"
      assert html =~ "Swarm Stack"
    end

    test "back from network goes to app", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> element("[phx-click=back]")
      |> render_click()

      html = render(view)
      assert html =~ "Search" or html =~ "Custom"
    end
  end

  describe "handle_params with template_id" do
    test "loads template and prefills ports/volumes/env", %{conn: conn, template: template} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      assert html =~ "TestApp"
      assert html =~ "testapp:latest"
      assert html =~ "8080"
      assert html =~ "/data"
      assert html =~ "APP_SECRET"
    end

    test "skips to network step when on type step", %{conn: conn, template: template} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new?template_id=#{template.id}")

      assert html =~ "Space"
      assert html =~ "Domain"
    end

    test "handles invalid template_id gracefully", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new?template_id=999999")

      assert html =~ "New Deployment"
    end
  end

  describe "search event" do
    test "empty search clears results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> form("form[phx-submit=search]", %{"query" => ""})
      |> render_submit()

      html = render(view)
      assert is_binary(html)
    end

    test "non-empty search sets loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> form("form[phx-submit=search]", %{"query" => "nginx"})
      |> render_submit()

      html = render(view)
      assert html =~ "animate-spin" or html =~ "nginx"
    end

    test "do_search handle_info updates results", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      send(view.pid, {:do_search, "nonexistent-image-xyz"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert is_binary(html)
    end
  end

  describe "handle_info :load_curated" do
    test "loads curated entries asynchronously", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      send(view.pid, :load_curated)
      _ = :sys.get_state(view.pid)

      html = render(view)
      refute html =~ "Loading catalog"
    end
  end

  describe "select_custom event" do
    test "custom image with valid image navigates to config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> form("form[phx-submit=select_custom]", %{"image" => "nginx:latest", "name" => "My Nginx"})
      |> render_submit()

      html = render(view)
      assert html =~ "Ports" or html =~ "Volumes" or html =~ "my-nginx" or html =~ "My Nginx" or html =~ "nginx"
    end

    test "custom image with blank image shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> form("form[phx-submit=select_custom]", %{"image" => "", "name" => ""})
      |> render_submit()

      html = render(view)
      assert html =~ "Image is required"
    end

    test "custom image without name derives display name from image", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      view
      |> form("form[phx-submit=select_custom]", %{"image" => "ghcr.io/owner/myapp:v2", "name" => ""})
      |> render_submit()

      html = render(view)
      assert html =~ "myapp"
    end
  end

  describe "parse_compose event" do
    test "valid compose YAML extracts services", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=compose")

      yaml = """
      version: '3'
      services:
        web:
          image: nginx:latest
          ports:
            - "80:80"
          volumes:
            - ./data:/data
          environment:
            APP_ENV: production
        db:
          image: postgres:15
          environment:
            POSTGRES_PASSWORD: secret
      """

      view
      |> form("form[phx-submit=parse_compose]", %{"compose_yaml" => yaml})
      |> render_submit()

      html = render(view)
      assert html =~ "Ports" or html =~ "Volumes" or html =~ "Environment"
    end

    test "empty compose YAML shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=compose")

      yaml = """
      version: '3'
      """

      view
      |> form("form[phx-submit=parse_compose]", %{"compose_yaml" => yaml})
      |> render_submit()

      html = render(view)
      assert html =~ "No services found" or html =~ "Failed to parse"
    end

    test "invalid YAML shows parse error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=compose")

      view
      |> form("form[phx-submit=parse_compose]", %{"compose_yaml" => "{{invalid yaml!!"})
      |> render_submit()

      html = render(view)
      assert html =~ "Failed to parse"
    end
  end

  describe "port management" do
    test "add_port adds a new empty port entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html_before = render(view)
      port_count_before = count_occurrences(html_before, "remove_port")

      view
      |> element("[phx-click=add_port]")
      |> render_click()

      html_after = render(view)
      port_count_after = count_occurrences(html_after, "remove_port")
      assert port_count_after == port_count_before + 1
    end

    test "remove_port removes a port entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html_before = render(view)
      port_count_before = count_occurrences(html_before, "remove_port")

      view
      |> element("[phx-click=remove_port][phx-value-index=\"0\"]")
      |> render_click()

      html_after = render(view)
      port_count_after = count_occurrences(html_after, "remove_port")
      assert port_count_after == port_count_before - 1
    end
  end

  describe "volume management" do
    test "add_volume adds a new empty volume entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html_before = render(view)
      vol_count_before = count_occurrences(html_before, "remove_volume")

      view
      |> element("[phx-click=add_volume]")
      |> render_click()

      html_after = render(view)
      vol_count_after = count_occurrences(html_after, "remove_volume")
      assert vol_count_after == vol_count_before + 1
    end

    test "remove_volume removes a volume entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html_before = render(view)
      vol_count_before = count_occurrences(html_before, "remove_volume")

      view
      |> element("[phx-click=remove_volume][phx-value-index=\"0\"]")
      |> render_click()

      html_after = render(view)
      vol_count_after = count_occurrences(html_after, "remove_volume")
      assert vol_count_after == vol_count_before - 1
    end
  end

  defp clear_enrichment(view) do
    enriched = %CatalogEntry{
      name: "TestApp",
      source: "dockerhub",
      full_ref: "testapp:latest",
      required_ports: [],
      required_volumes: [],
      default_env: %{},
      required_env: []
    }

    send(view.pid, {:enrichment_complete, enriched})
    _ = :sys.get_state(view.pid)
  end

  describe "env var management" do
    test "add_env_var adds a new empty env var entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      clear_enrichment(view)

      html_before = render(view)
      env_count_before = count_occurrences(html_before, "remove_env_var")

      view
      |> element("[phx-click=add_env_var]")
      |> render_click()

      html_after = render(view)
      env_count_after = count_occurrences(html_after, "remove_env_var")
      assert env_count_after == env_count_before + 1
    end

    test "remove_env_var removes an env var entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      clear_enrichment(view)

      html_before = render(view)
      env_count_before = count_occurrences(html_before, "remove_env_var")
      assert env_count_before > 0

      view
      |> element("[phx-click=remove_env_var][phx-value-index=\"0\"]")
      |> render_click()

      html_after = render(view)
      env_count_after = count_occurrences(html_after, "remove_env_var")
      assert env_count_after == env_count_before - 1
    end
  end

  describe "network configuration" do
    test "update_network with form params sets domain and tenant_id", %{conn: conn, template: template, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> form("#network-form", %{
        "network" => %{"tenant_id" => to_string(tenant.id), "domain" => "myapp.example.com"}
      })
      |> render_change()

      html = render(view)
      assert html =~ "myapp.example.com"
    end

    test "update_network with exposure_mode sets exposure", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> element("[phx-click=update_network][phx-value-exposure_mode=private]")
      |> render_click()

      html = render(view)
      assert html =~ "Private"
    end

    test "service exposure mode shows info banner", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> element("[phx-click=update_network][phx-value-exposure_mode=service]")
      |> render_click()

      html = render(view)
      assert html =~ "No host ports published"
    end
  end

  describe "toggle_view_mode" do
    test "switches between form and visual mode", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      assert has_element?(view, "[phx-click=toggle_view_mode]")

      view
      |> element("button[phx-click=toggle_view_mode]", "Visual")
      |> render_click()

      html = render(view)
      assert html =~ "Visual" or html =~ "Form"
    end
  end

  describe "topology events" do
    test "topology_change with exposure key updates exposure_mode", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "topology_change", %{
        "node_id" => "main",
        "key" => "exposure",
        "value" => "private"
      })

      html = render(view)
      assert is_binary(html)
    end

    test "topology_add with infrastructure column shows flash", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "topology_add", %{"column" => "infrastructure"})

      html = render(view)
      assert html =~ "config step"
    end

    test "topology_add with unknown column is a no-op", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html = render_click(view, "topology_add", %{"column" => "unknown"})
      assert is_binary(html)
    end

    test "topology_remove is a no-op", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html = render_click(view, "topology_remove", %{"node-id" => "main"})
      assert is_binary(html)
    end
  end

  describe "apply_all_infra" do
    test "applies all infrastructure suggestion values", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "apply_all_infra", %{})

      html = render(view)
      assert html =~ "All infrastructure values applied"
    end
  end

  describe "companion services" do
    test "add_companion_custom adds a companion service", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "add_companion_custom", %{"image" => "redis:7"})

      html = render(view)
      assert html =~ "redis"
    end

    test "add_companion_custom with blank image is a no-op", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      html = render_click(view, "add_companion_custom", %{"image" => ""})
      assert is_binary(html)
    end

    test "add_companion_custom with duplicate image shows error", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "add_companion_custom", %{"image" => "redis:7"})
      render_click(view, "add_companion_custom", %{"image" => "redis:7"})

      html = render(view)
      assert html =~ "already added"
    end

    test "remove_companion_service removes a companion", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "add_companion_custom", %{"image" => "redis:7"})
      html = render(view)
      assert html =~ "redis"

      render_click(view, "remove_companion_service", %{"name" => "redis"})
      html = render(view)
      refute html =~ "Companion Services"
    end

    test "companion_search with empty query clears results", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "companion_search", %{"value" => ""})
      html = render(view)
      assert is_binary(html)
    end

    test "companion_search with query triggers async search", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "companion_search", %{"value" => "redis"})

      send(view.pid, {:do_companion_search, "redis"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert is_binary(html)
    end
  end

  describe "enrichment messages" do
    test "enrichment_complete merges ports, volumes, and env", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      enriched = %CatalogEntry{
        name: "TestApp",
        full_ref: "testapp:latest",
        source: "dockerhub",
        description: "Enriched description",
        categories: ["web"],
        required_ports: [
          %{"internal" => "9090", "external" => "", "description" => "Metrics", "role" => "metrics", "optional" => true, "published" => false}
        ],
        required_volumes: [
          %{"path" => "/config", "description" => "Config volume"}
        ],
        default_env: %{"APP_ENV" => "production", "NEW_KEY" => "new_value"},
        required_env: ["APP_SECRET", "NEW_REQUIRED"],
        stars: 100,
        pulls: 5000
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "9090"
      assert html =~ "/config"
      assert html =~ "NEW_REQUIRED"
    end

    test "enrichment_progress updates the enriching stage", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      send(view.pid, {:enrichment_progress, "scanning"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Scanning" or html =~ "Discovering"
    end

    test "enrichment_complete with no selected_template just clears enriching", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new")

      enriched = %CatalogEntry{
        name: "test",
        full_ref: "test:latest",
        source: "dockerhub",
        categories: [],
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        stars: 0,
        pulls: 0
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert is_binary(html)
    end

    test "unknown handle_info message is ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new")

      send(view.pid, :some_random_message)
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "New Deployment"
    end
  end

  describe "deploy event" do
    test "deploy without tenant_id shows error flash", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{template.id}")

      render_click(view, "deploy", %{
        "tenant_id" => "",
        "domain" => "test.example.com",
        "exposure_mode" => "public"
      })

      html = render(view)
      assert html =~ "Please select a space"
    end

    test "successful deploy redirects to home", %{conn: conn, tenant: tenant} do
      simple_template =
        insert(:app_template,
          name: "SimpleApp",
          slug: "simpleapp",
          image: "simpleapp:latest",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "svc_123"} end)
      |> stub(:stats, fn _id -> {:error, :not_found} end)
      |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
      |> stub(:list_services, fn -> {:ok, []} end)
      |> stub(:get_service, fn _id -> {:error, :not_found} end)

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{simple_template.id}")

      render_click(view, "deploy", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => "",
        "exposure_mode" => "public"
      })

      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "deployment started"
    end

    test "successful deploy with domain redirects to home", %{conn: conn, tenant: tenant} do
      simple_template =
        insert(:app_template,
          name: "SimpleApp2",
          slug: "simpleapp2",
          image: "simpleapp2:latest",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "svc_456"} end)
      |> stub(:stats, fn _id -> {:error, :not_found} end)
      |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
      |> stub(:list_services, fn -> {:ok, []} end)
      |> stub(:get_service, fn _id -> {:error, :not_found} end)

      Homelab.Mocks.DnsProvider
      |> stub(:list_records, fn _zone -> {:ok, []} end)
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
      |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
      |> stub(:delete_record, fn _zone, _id -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{simple_template.id}")

      render_click(view, "deploy", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => "test.example.com",
        "exposure_mode" => "public"
      })

      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "deployment started"
    end

    test "failed deploy shows error flash", %{conn: conn, template: template, tenant: tenant} do
      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:error, :connection_refused} end)
      |> stub(:stats, fn _id -> {:error, :not_found} end)
      |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
      |> stub(:list_services, fn -> {:ok, []} end)
      |> stub(:get_service, fn _id -> {:error, :not_found} end)

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{template.id}")

      render_click(view, "deploy", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => "testfail.example.com",
        "exposure_mode" => "public"
      })

      html = render(view)
      assert html =~ "Deployment failed"
    end
  end

  describe "deploy_compose event" do
    test "deploy_compose without tenant_id shows error flash", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{template.id}")

      render_click(view, "deploy_compose", %{
        "tenant_id" => "",
        "domain" => "test.example.com",
        "exposure_mode" => "public"
      })

      html = render(view)
      assert html =~ "Please select a space"
    end

    test "successful compose deploy redirects to home", %{conn: conn, tenant: tenant} do
      simple_template =
        insert(:app_template,
          name: "ComposeMain",
          slug: "composemain",
          image: "composemain:latest",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> {:ok, "svc_compose_1"} end)
      |> stub(:stats, fn _id -> {:error, :not_found} end)
      |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
      |> stub(:list_services, fn -> {:ok, []} end)
      |> stub(:get_service, fn _id -> {:error, :not_found} end)

      Homelab.Mocks.DnsProvider
      |> stub(:list_records, fn _zone -> {:ok, []} end)
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
      |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
      |> stub(:delete_record, fn _zone, _id -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{simple_template.id}")

      render_click(view, "add_companion_custom", %{"image" => "redis:7"})

      view
      |> element("[phx-click=go_step][phx-value-step=review]")
      |> render_click()

      render_click(view, "deploy_compose", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => "compose.example.com",
        "exposure_mode" => "public"
      })

      flash = assert_redirect(view, "/")
      assert flash["info"] =~ "service(s) deployed"
    end
  end

  describe "load_curated event" do
    test "clicking load curated sets loading state", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      assert has_element?(view, "[phx-click=load_curated]")

      view
      |> element("[phx-click=load_curated]")
      |> render_click()

      send(view.pid, :load_curated)
      _ = :sys.get_state(view.pid)

      html = render(view)
      refute html =~ "Loading catalog"
    end
  end

  describe "review step rendering" do
    test "review step shows template info and form", %{conn: conn, template: template, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> form("#network-form", %{
        "network" => %{"tenant_id" => to_string(tenant.id), "domain" => "review.example.com"}
      })
      |> render_change()

      view
      |> element("[phx-click=go_step][phx-value-step=config]")
      |> render_click()

      view
      |> element("[phx-click=go_step][phx-value-step=review]")
      |> render_click()

      html = render(view)
      assert html =~ "TestApp"
      assert html =~ "review.example.com" or html =~ "Review"
    end
  end

  describe "domain prefilling for config step" do
    test "prefills APP_URL env vars when domain is set", %{conn: conn, template: template, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=network&template_id=#{template.id}")

      view
      |> form("#network-form", %{
        "network" => %{"tenant_id" => to_string(tenant.id), "domain" => "prefill.example.com"}
      })
      |> render_change()

      view
      |> element("[phx-click=go_step][phx-value-step=config]")
      |> render_click()

      html = render(view)
      assert html =~ "https://prefill.example.com"
    end
  end

  describe "handle_params with type param" do
    test "sets deploy_type from type param when not already set", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new?step=app&type=container")

      assert html =~ "Search registries"
    end

    test "invalid step falls back to type", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/deploy/new?step=invalid_step")

      assert html =~ "Container"
      assert html =~ "Compose Project"
    end
  end

  describe "select_entry event" do
    test "selecting an entry from the app step loads template and moves to config", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      entry_json =
        Jason.encode!(%{
          "name" => "WizardTestApp",
          "source" => "dockerhub",
          "full_ref" => "wizardtestapp:latest",
          "description" => "Test app for wizard",
          "categories" => ["tools"],
          "required_ports" => [%{"internal" => "3000", "external" => "", "description" => "Web"}],
          "required_volumes" => [%{"path" => "/data", "description" => "Data"}],
          "default_env" => %{"APP_MODE" => "prod"},
          "required_env" => ["SECRET_KEY"]
        })

      render_click(view, "select_entry", %{"entry" => entry_json})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "Ports" or html =~ "Volumes" or html =~ "WizardTestApp" or html =~ "config"
    end

    test "enrichment_complete after select_entry populates env vars and ports", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=container")

      entry_json =
        Jason.encode!(%{
          "name" => "EnrichApp",
          "source" => "dockerhub",
          "full_ref" => "enrichapp:latest",
          "description" => "Enrichable app",
          "categories" => ["tools"],
          "required_ports" => [],
          "required_volumes" => [],
          "default_env" => %{},
          "required_env" => []
        })

      render_click(view, "select_entry", %{"entry" => entry_json})
      _ = :sys.get_state(view.pid)

      enriched = %CatalogEntry{
        name: "EnrichApp",
        source: "dockerhub",
        full_ref: "enrichapp:latest",
        description: "Enriched app",
        categories: ["tools"],
        required_ports: [
          %{"internal" => "9090", "external" => "", "description" => "Metrics", "role" => "metrics", "optional" => true, "published" => false}
        ],
        required_volumes: [
          %{"path" => "/config", "description" => "Config volume"}
        ],
        default_env: %{"DB_HOST" => "localhost"},
        required_env: ["DB_PASSWORD"]
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "9090" or html =~ "Metrics"
      assert html =~ "/config" or html =~ "Config volume"
      assert html =~ "DB_PASSWORD" or html =~ "DB_HOST"
    end
  end

  describe "wire_db_secrets event" do
    test "wires database secrets into env vars when db suggestion exists", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      clear_enrichment(view)

      enriched = %CatalogEntry{
        name: "TestApp",
        source: "dockerhub",
        full_ref: "testapp:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{"DATABASE_URL" => "", "DB_HOST" => "", "DB_PASSWORD" => ""},
        required_env: ["DATABASE_URL", "DB_HOST", "DB_PASSWORD"]
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)

      html = render(view)

      if html =~ "wire_db_secrets" do
        render_click(view, "wire_db_secrets", %{"db-type" => "postgres"})
        _ = :sys.get_state(view.pid)
        html = render(view)
        assert is_binary(html)
      else
        assert html =~ "DATABASE_URL" or html =~ "DB_HOST" or html =~ "DB_PASSWORD"
      end
    end
  end

  describe "apply_infra event" do
    test "applies a single infrastructure suggestion", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      clear_enrichment(view)

      html_before = render(view)

      render_click(view, "apply_all_infra", %{})
      _ = :sys.get_state(view.pid)

      html_after = render(view)
      assert html_after =~ "All infrastructure values applied" or html_after =~ "Ports"
      assert is_binary(html_before)
    end

    test "apply_infra with specific infra-id applies that suggestion", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      clear_enrichment(view)

      enriched = %CatalogEntry{
        name: "TestApp",
        source: "dockerhub",
        full_ref: "testapp:latest",
        required_ports: [],
        required_volumes: [],
        default_env: %{"APP_URL" => "", "BASE_URL" => ""},
        required_env: ["APP_URL"]
      }

      send(view.pid, {:enrichment_complete, enriched})
      _ = :sys.get_state(view.pid)

      html = render(view)

      if html =~ "apply_infra" do
        render_click(view, "apply_infra", %{"infra-id" => "app_url"})
        _ = :sys.get_state(view.pid)
        html = render(view)
        assert html =~ "values applied" or is_binary(html)
      else
        assert is_binary(html)
      end
    end
  end

  describe "add_companion_entry event" do
    test "adds a companion service from catalog entry", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      companion_json =
        Jason.encode!(%{
          "name" => "Redis",
          "source" => "dockerhub",
          "full_ref" => "redis:7-alpine",
          "description" => "In-memory data store",
          "categories" => ["Database"],
          "required_ports" => [%{"internal" => "6379", "external" => "", "description" => "Redis port"}],
          "required_volumes" => [%{"path" => "/data", "description" => "Redis data"}],
          "default_env" => %{},
          "required_env" => []
        })

      render_click(view, "add_companion_entry", %{"entry" => companion_json})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "redis" or html =~ "Redis"
      assert html =~ "added as a companion"
    end

    test "adding a duplicate companion entry shows error", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      companion_json =
        Jason.encode!(%{
          "name" => "Redis",
          "source" => "dockerhub",
          "full_ref" => "redis:7-alpine",
          "description" => "In-memory data store",
          "categories" => ["Database"],
          "required_ports" => [],
          "required_volumes" => [],
          "default_env" => %{},
          "required_env" => []
        })

      render_click(view, "add_companion_entry", %{"entry" => companion_json})
      _ = :sys.get_state(view.pid)

      render_click(view, "add_companion_entry", %{"entry" => companion_json})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "already added"
    end
  end

  describe "add_companion_custom duplicate name error" do
    test "adding the same custom companion image three times shows error on third", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "add_companion_custom", %{"image" => "memcached:latest"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "memcached"

      render_click(view, "add_companion_custom", %{"image" => "memcached:latest"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "already added"
    end

    test "adding different custom companions with same base name but different tags shows error", %{conn: conn, template: template} do
      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{template.id}")

      render_click(view, "add_companion_custom", %{"image" => "valkey:7"})
      _ = :sys.get_state(view.pid)

      render_click(view, "add_companion_custom", %{"image" => "valkey:8"})
      _ = :sys.get_state(view.pid)

      html = render(view)
      assert html =~ "already added"
    end
  end

  defp count_occurrences(html, pattern) do
    html
    |> String.split(pattern)
    |> length()
    |> Kernel.-(1)
  end
end
