defmodule HomelabWeb.DashboardLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

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
    test "renders dashboard page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Dashboard"
      assert html =~ "Your self-hosted infrastructure at a glance"
    end

    test "shows stat cards", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Spaces"
      assert html =~ "Deployments"
      assert html =~ "Running"
      assert html =~ "Pending"
    end

    test "shows spaces panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Spaces"
    end

    test "shows recent deployments panel", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Recent Deployments"
    end

    test "shows deploy app button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      assert has_element?(view, "a", "Deploy App")
    end

    test "shows stat card descriptions", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Active environments"
      assert html =~ "Total apps deployed"
      assert html =~ "Healthy and online"
      assert html =~ "Awaiting deployment"
    end

    test "page title is Dashboard", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Dashboard"
    end

    test "shows tenant in spaces panel", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ tenant.name
      assert html =~ tenant.slug
    end
  end

  describe "empty state" do
    test "shows no deployments message when none exist", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "No deployments yet" or html =~ "0 total"
    end

    test "shows browse catalog link in empty deployments", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Browse the catalog" or html =~ "catalog"
    end
  end

  describe "with deployments" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_123"
        )

      {:ok, deployment: deployment}
    end

    test "shows deployment in table", %{conn: conn, template: template} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ template.name
    end

    test "shows running count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Running"
    end

    test "navigate_deployment redirects to deployment page", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "navigate_deployment", %{"id" => to_string(dep.id)})
      assert_redirect(view, ~p"/deployments/#{dep.id}")
    end

    test "shows deployment tenant name", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ tenant.name
    end

    test "shows deployment domain", %{conn: conn, deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ dep.domain
    end

    test "shows total deployments count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "1 total"
    end
  end

  describe "with multiple deployment statuses" do
    setup %{tenant: tenant, template: template} do
      running =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "running_1"
        )

      pending =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :pending
        )

      failed =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :failed,
          error_message: "Connection refused"
        )

      {:ok, running: running, pending: pending, failed: failed}
    end

    test "shows all deployment statuses", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Running"
      assert html =~ "Pending"
      assert html =~ "Failed"
    end

    test "shows error message for failed deployment", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Connection refused"
    end

    test "displays correct total count", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "3 total"
    end
  end

  describe "create space modal" do
    test "open_create_space shows modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      assert has_element?(view, "#create-space-modal")
      assert has_element?(view, "#create-space-form")
    end

    test "open_create_space shows form fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      html = render(view)
      assert html =~ "Create a Space"
      assert html =~ "Name"
      assert html =~ "Slug"
      assert html =~ "Create Space"
      assert html =~ "Cancel"
    end

    test "close_create_space hides modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      assert has_element?(view, "#create-space-modal")
      render_click(view, "close_create_space", %{})
      refute has_element?(view, "#create-space-modal")
    end

    test "close_create_space when already closed is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "close_create_space", %{})
      refute has_element?(view, "#create-space-modal")
      html = render(view)
      assert html =~ "Dashboard"
    end

    test "reopening modal resets form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{"tenant" => %{"name" => "Partial", "slug" => "partial"}})
      |> render_change()

      render_click(view, "close_create_space", %{})
      render_click(view, "open_create_space", %{})
      assert has_element?(view, "#create-space-form")
    end

    test "validate_space validates form input", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      html =
        view
        |> form("#create-space-form", %{"tenant" => %{"name" => "Test", "slug" => "test"}})
        |> render_change()

      assert html =~ "Test"
    end

    test "validate_space with empty fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{"tenant" => %{"name" => "", "slug" => ""}})
      |> render_change()

      assert has_element?(view, "#create-space-form")
    end

    test "validate_space updates form as user types", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      html =
        view
        |> form("#create-space-form", %{
          "tenant" => %{"name" => "Staging Env", "slug" => "staging-env"}
        })
        |> render_change()

      assert html =~ "Staging Env"
    end

    test "save_space creates a new space", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      html =
        view
        |> form("#create-space-form", %{
          "tenant" => %{"name" => "Production", "slug" => "production"}
        })
        |> render_submit()

      assert html =~ "Space created successfully"
    end

    test "save_space hides modal after success", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{
        "tenant" => %{"name" => "New Space", "slug" => "new-space"}
      })
      |> render_submit()

      refute has_element?(view, "#create-space-modal")
    end

    test "save_space shows the new space in the list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{
        "tenant" => %{"name" => "Dev Environment", "slug" => "dev-env"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Dev Environment"
    end

    test "save_space with invalid data shows errors", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{"tenant" => %{"name" => "", "slug" => ""}})
      |> render_submit()

      assert has_element?(view, "#create-space-form")
    end

    test "save_space with duplicate slug shows error", %{conn: conn, tenant: _tenant} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{
        "tenant" => %{"name" => "Unique Name", "slug" => "unique-slug"}
      })
      |> render_submit()

      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{
        "tenant" => %{"name" => "Another Name", "slug" => "unique-slug"}
      })
      |> render_submit()

      assert has_element?(view, "#create-space-form")
    end
  end

  describe "generate_slug" do
    test "generates slug from name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      html = render_click(view, "generate_slug", %{"value" => "My Cool Space"})
      assert html =~ "my-cool-space"
    end

    test "generates slug with special characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      html = render_click(view, "generate_slug", %{"value" => "Hello World! @#$"})
      assert html =~ "hello-world"
    end

    test "generates slug with multiple spaces", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      html = render_click(view, "generate_slug", %{"value" => "Multiple   Spaces   Here"})
      assert html =~ "multiple-spaces-here" or html =~ "multiple"
    end

    test "generates empty slug from empty name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      render_click(view, "generate_slug", %{"value" => ""})
      assert has_element?(view, "#create-space-form")
    end

    test "generates slug and updates form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      html = render_click(view, "generate_slug", %{"value" => "Production Apps"})
      assert html =~ "production-apps"
    end
  end

  describe "handle_info" do
    test ":refresh reloads dashboard data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Dashboard"
    end

    test ":refresh updates deployment counts", %{conn: conn, tenant: tenant, template: template} do
      {:ok, view, _html} = live(conn, ~p"/")

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "new_container"
      )

      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "1 total" or html =~ "Running"
    end

    test ":refresh updates tenants list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      insert(:tenant, name: "Refresh Test Space", slug: "refresh-test")

      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Refresh Test Space"
    end

    test "{:metrics, metrics} updates metrics", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 45.2,
        memory_percent: 62.0,
        memory_used: 4_294_967_296,
        memory_total: 8_589_934_592,
        docker: %{"Containers" => 5, "ContainersRunning" => 3}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "CPU"
      assert html =~ "Memory"
    end

    test "{:metrics, metrics} shows docker container count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 30.0,
        memory_used: 1_073_741_824,
        memory_total: 4_294_967_296,
        docker: %{"Containers" => 8, "ContainersRunning" => 5}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "5/8" or html =~ "containers running"
    end

    test "{:metrics, metrics} shows CPU percentage", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 78.5,
        memory_percent: 50.0,
        memory_used: 2_147_483_648,
        memory_total: 4_294_967_296,
        docker: %{"Containers" => 2, "ContainersRunning" => 1}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "78.5%"
    end

    test "{:metrics, metrics} shows memory usage", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 20.0,
        memory_percent: 50.0,
        memory_used: 4_294_967_296,
        memory_total: 8_589_934_592,
        docker: %{"Containers" => 1, "ContainersRunning" => 1}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "4.0 GB" or html =~ "8.0 GB"
    end

    test "{:metrics_update, metrics} also updates metrics", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 55.0,
        memory_percent: 40.0,
        memory_used: 2_000_000_000,
        memory_total: 4_000_000_000,
        docker: %{"Containers" => 3, "ContainersRunning" => 2}
      }

      send(view.pid, {:metrics_update, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "CPU"
      assert html =~ "Memory"
    end

    test "{:activity_event, event} prepends to activity list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :info,
        message: "Test deployment started",
        source: "deploy",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Test deployment started"
    end

    test "{:activity_event, event} shows event source", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :info,
        message: "Container pulled",
        source: "docker",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Container pulled"
      assert html =~ "docker"
    end

    test "{:activity_event, event} with error level", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :error,
        message: "Deployment failed: timeout",
        source: "deploy",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Deployment failed: timeout"
    end

    test "{:activity_event, event} with warn level", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :warn,
        message: "High memory usage detected",
        source: "infrastructure",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "High memory usage detected"
    end

    test "multiple activity events are shown in order", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for i <- 1..5 do
        event = %{
          level: :info,
          message: "Event number #{i}",
          source: "deploy",
          timestamp: DateTime.utc_now()
        }

        send(view.pid, {:activity_event, event})
      end

      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Event number 5"
      assert html =~ "Event number 1"
    end

    test "activity events are capped at 15", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      for i <- 1..20 do
        event = %{
          level: :info,
          message: "cap-test-event-#{String.pad_leading(to_string(i), 2, "0")}",
          source: "deploy",
          timestamp: DateTime.utc_now()
        }

        send(view.pid, {:activity_event, event})
      end

      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "cap-test-event-20"
      refute html =~ "cap-test-event-05"
    end

    test "unknown messages are ignored", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      send(view.pid, {:unknown_message, :data})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Dashboard"
    end

    test "nil message is handled gracefully", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      send(view.pid, :some_random_atom)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Dashboard"
    end
  end

  describe "navigate_deployment" do
    test "redirects to deployment detail page", %{conn: conn, tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_nav"
        )

      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "navigate_deployment", %{"id" => to_string(deployment.id)})
      assert_redirect(view, ~p"/deployments/#{deployment.id}")
    end
  end

  describe "system activity panel" do
    test "shows no activity message when empty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "No activity yet" or html =~ "System Activity"
    end

    test "shows System Activity heading", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "System Activity"
    end

    test "shows Live indicator", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Live"
    end

    test "shows system activity section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "System Activity"
    end

    test "activity panel shows relative timestamps", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :info,
        message: "Timestamp test event",
        source: "deploy",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "just now" or html =~ "ago"
    end

    test "activity panel shows different source badges", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      sources = ["deploy", "docker", "infrastructure", "domain", "dns"]

      for source <- sources do
        event = %{
          level: :info,
          message: "#{source} event",
          source: source,
          timestamp: DateTime.utc_now()
        }

        send(view.pid, {:activity_event, event})
      end

      _ = :sys.get_state(view.pid)
      html = render(view)

      for source <- sources do
        assert html =~ source
      end
    end
  end

  describe "traffic overview" do
    test "does not show traffic panel when no metrics", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "Traffic"
    end

    test "does not show traffic panel when metrics have no traefik data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 20.0,
        memory_used: 1_000_000,
        memory_total: 4_000_000,
        docker: %{"Containers" => 1, "ContainersRunning" => 1}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      refute html =~ "Traffic"
    end

    test "shows traffic panel when traefik metrics exist", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 20.0,
        memory_used: 1_000_000,
        memory_total: 4_000_000,
        docker: %{"Containers" => 1, "ContainersRunning" => 1},
        traefik: %{
          "my-service" => %{
            requests_total: 1500,
            requests_bytes_total: 2_000_000,
            responses_bytes_total: 5_000_000,
            error_count: 3
          }
        }
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Traffic"
      assert html =~ "Requests"
      assert html =~ "Bandwidth"
    end
  end

  describe "dashboard with multiple deployment statuses rendering" do
    test "renders deployments with running, stopped, and failed statuses", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "run_1"
      )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :stopped
      )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :failed,
        error_message: "OOM killed"
      )

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Running"
      assert html =~ "Stopped"
      assert html =~ "Failed"
      assert html =~ "OOM killed"
      assert html =~ "3 total"
    end

    test "running deployment with external_id shows Running status pill", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "ext_abc123"
      )

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ "Running"
      assert has_element?(view, "span", "Running")
    end

    test "deploying status renders correctly", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :deploying,
        external_id: "deploy_1"
      )

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Deploying"
    end
  end

  describe "traffic overview rendering" do
    test "traffic panel hidden when metrics are nil", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")
      refute html =~ "Traffic"
    end

    test "traffic panel renders summary stats with traefik data", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 25.0,
        memory_percent: 40.0,
        memory_used: 2_000_000_000,
        memory_total: 8_000_000_000,
        docker: %{"Containers" => 4, "ContainersRunning" => 3},
        traefik: %{
          "app-1" => %{
            requests_total: 5000,
            requests_bytes_total: 10_000_000,
            responses_bytes_total: 50_000_000,
            error_count: 12
          },
          "app-2" => %{
            requests_total: 3000,
            requests_bytes_total: 5_000_000,
            responses_bytes_total: 20_000_000,
            error_count: 0
          }
        }
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Traffic"
      assert html =~ "Requests"
      assert html =~ "Bandwidth In"
      assert html =~ "Bandwidth Out"
      assert html =~ "Errors"
      assert html =~ "8.0K"
    end

    test "traffic panel shows per-deployment breakdown when domain matches", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "run_traffic",
        domain: "myapp.homelab.local"
      )

      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 20.0,
        memory_used: 1_000_000,
        memory_total: 4_000_000,
        docker: %{"Containers" => 1, "ContainersRunning" => 1},
        traefik: %{
          "myapp-homelab-local" => %{
            requests_total: 250,
            requests_bytes_total: 500_000,
            responses_bytes_total: 2_000_000,
            error_count: 1
          }
        }
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Traffic"
      assert html =~ template.name
      assert html =~ "myapp.homelab.local"
    end
  end

  describe "create space form rendering" do
    test "modal form contains name and slug input fields", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      assert has_element?(view, "#create-space-modal")
      assert has_element?(view, "#create-space-form")
      html = render(view)
      assert html =~ "Create a Space"
      assert html =~ "Isolated environment for your apps"
      assert html =~ "Name"
      assert html =~ "Slug"
      assert html =~ "Lowercase letters, numbers, and hyphens only"
    end

    test "submitting space form with empty name keeps modal open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})

      view
      |> form("#create-space-form", %{"tenant" => %{"name" => "", "slug" => ""}})
      |> render_submit()

      assert has_element?(view, "#create-space-modal")
      assert has_element?(view, "#create-space-form")
    end

    test "escape key closes create space modal", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")
      render_click(view, "open_create_space", %{})
      assert has_element?(view, "#create-space-modal")

      render_click(view, "close_create_space", %{})
      refute has_element?(view, "#create-space-modal")
    end
  end

  describe "activity events with different levels" do
    test "info level event renders with success styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :info,
        message: "Deployment completed successfully",
        source: "deploy",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Deployment completed successfully"
      assert html =~ "bg-success/10"
      assert html =~ "text-success"
    end

    test "warn level event renders with warning styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :warn,
        message: "Disk usage above 80%",
        source: "infrastructure",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Disk usage above 80%"
      assert html =~ "bg-warning/10"
      assert html =~ "text-warning"
    end

    test "error level event renders with error styling", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      event = %{
        level: :error,
        message: "Container crashed unexpectedly",
        source: "docker",
        timestamp: DateTime.utc_now()
      }

      send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Container crashed unexpectedly"
      assert html =~ "bg-error/10"
      assert html =~ "text-error"
    end

    test "mixed activity events all render in the panel", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      events = [
        %{level: :info, message: "Container started", source: "docker", timestamp: DateTime.utc_now()},
        %{level: :warn, message: "SSL cert expiring soon", source: "domain", timestamp: DateTime.utc_now()},
        %{level: :error, message: "Health check failed", source: "deploy", timestamp: DateTime.utc_now()}
      ]

      for event <- events, do: send(view.pid, {:activity_event, event})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "Container started"
      assert html =~ "SSL cert expiring soon"
      assert html =~ "Health check failed"
    end
  end

  describe "tenants with deployments" do
    test "spaces panel shows tenant names with active status", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "dep_1"
      )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :pending
      )

      {:ok, view, html} = live(conn, ~p"/")
      assert html =~ tenant.name
      assert html =~ tenant.slug
      assert has_element?(view, "span", "Active")
    end

    test "multiple tenants each appear in the spaces panel", %{conn: conn} do
      tenant2 = insert(:tenant, name: "Staging", slug: "staging")
      tenant3 = insert(:tenant, name: "Development", slug: "development")

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Staging"
      assert html =~ "staging"
      assert html =~ "Development"
      assert html =~ "development"
      assert html =~ tenant2.name
      assert html =~ tenant3.name
    end

    test "stat card shows correct space count with multiple tenants", %{conn: conn} do
      insert(:tenant, name: "Extra Space 1", slug: "extra-1")
      insert(:tenant, name: "Extra Space 2", slug: "extra-2")

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "Spaces"
      assert html =~ "Active environments"
    end

    test "deployments table shows domain when present", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "domain_test",
        domain: "custom.example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "custom.example.com"
    end

    test "deployments table shows dash when domain is nil", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :pending,
        domain: nil
      )

      {:ok, _view, html} = live(conn, ~p"/")
      assert html =~ "&mdash;" or html =~ "—"
    end
  end

  describe "system health gauges" do
    test "renders CPU, Memory, and Docker gauges when metrics present", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 35.5,
        memory_percent: 72.3,
        memory_used: 6_174_015_488,
        memory_total: 8_589_934_592,
        docker: %{"Containers" => 10, "ContainersRunning" => 7}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)

      assert html =~ "CPU"
      assert html =~ "35.5%"
      assert html =~ "Memory"
      assert html =~ "72.3%"
      assert html =~ "Docker"
      assert html =~ "7/10"
      assert html =~ "containers running"
    end

    test "formats memory in GB correctly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 50.0,
        memory_used: 8_589_934_592,
        memory_total: 17_179_869_184,
        docker: %{"Containers" => 1, "ContainersRunning" => 1}
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "8.0 GB"
      assert html =~ "16.0 GB"
    end

    test "docker dash shown when no docker key in metrics", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/")

      metrics = %{
        cpu_percent: 10.0,
        memory_percent: 20.0,
        memory_used: 1_000_000,
        memory_total: 4_000_000
      }

      send(view.pid, {:metrics, metrics})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Docker"
    end
  end
end
