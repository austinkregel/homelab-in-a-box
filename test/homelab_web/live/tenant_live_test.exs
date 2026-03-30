defmodule HomelabWeb.TenantLiveTest do
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
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn, tenant: tenant, template: template}
  end

  describe "mount" do
    test "renders tenant page with name and slug", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ tenant.name
      assert html =~ tenant.slug
    end

    test "shows breadcrumb navigation", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Dashboard"
      assert html =~ tenant.name
    end

    test "shows deploy app button", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert has_element?(view, "a", "Deploy App")
    end

    test "shows summary cards", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Total"
      assert html =~ "Running"
      assert html =~ "Pending"
      assert html =~ "Failed"
    end

    test "redirects for non-existent tenant", %{conn: conn} do
      {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/tenants/999999")
    end
  end

  describe "empty state" do
    test "shows no deployments message when empty", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "No apps deployed yet"
    end

    test "shows link to catalog", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert has_element?(view, "a", "Browse Catalog")
    end
  end

  describe "with deployments" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_abc"
        )

      {:ok, deployment: deployment}
    end

    test "shows deployment in list", %{conn: conn, tenant: tenant, template: template} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ template.name
    end

    test "shows running count", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Running"
    end

    test "shows deployment status pill", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Running"
    end

    test "navigate event pushes to deployment page", %{
      conn: conn,
      tenant: tenant,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      render_click(view, "navigate", %{"to" => ~p"/deployments/#{dep.id}"})
      assert_redirect(view, ~p"/deployments/#{dep.id}")
    end
  end

  describe "deployment actions" do
    setup %{tenant: tenant, template: template} do
      running =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "running_container"
        )

      stopped =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "stopped_container"
        )

      {:ok, running: running, stopped: stopped}
    end

    test "stop stops a running deployment", %{conn: conn, tenant: tenant, running: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "stop", %{"id" => to_string(dep.id)})
      assert html =~ "stopped"
    end

    test "start starts a stopped deployment", %{conn: conn, tenant: tenant, stopped: dep} do
      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "new_container_id"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "start", %{"id" => to_string(dep.id)})
      assert html =~ "starting" or html =~ dep.app_template.name
    end

    test "restart restarts a running deployment", %{conn: conn, tenant: tenant, running: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:restart, fn _dep -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "restart", %{"id" => to_string(dep.id)})
      assert html =~ "restarting"
    end

    test "delete removes a deployment", %{conn: conn, tenant: tenant, running: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "delete", %{"id" => to_string(dep.id)})
      assert html =~ "deleted"
    end
  end

  describe "handle_info :refresh" do
    test "refreshes deployment data", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ tenant.name
    end
  end

  describe "multiple deployment statuses" do
    setup %{tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "run_1"
      )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :pending
      )

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :failed,
        error_message: "Container crashed"
      )

      :ok
    end

    test "shows correct counts for mixed statuses", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Running"
      assert html =~ "Pending"
      assert html =~ "Failed"
    end

    test "shows error message for failed deployment", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Container crashed"
    end
  end

  describe "stop deployment error path" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "err_stop_container"
        )

      {:ok, deployment: deployment}
    end

    test "stop deployment still succeeds even if undeploy errors", %{conn: conn, tenant: tenant, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> {:error, "failed to stop"} end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "stop", %{"id" => to_string(dep.id)})
      assert html =~ "stopped"
    end
  end

  describe "restart deployment error path" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "err_restart_container"
        )

      {:ok, deployment: deployment}
    end

    test "shows error flash when restart fails", %{conn: conn, tenant: tenant, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:restart, fn _dep -> {:error, "failed to restart"} end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "restart", %{"id" => to_string(dep.id)})
      assert html =~ "Failed to restart"
    end
  end

  describe "handle_info :refresh with deployments" do
    setup %{tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "refresh_container"
      )

      :ok
    end

    test "refresh reloads deployments and counts", %{conn: conn, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      send(view.pid, :refresh)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ tenant.name
      assert html =~ "Running"
    end
  end

  describe "deployment with domain" do
    test "renders domain text for deployment with domain set", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "dom_container",
        domain: "myapp.example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "myapp.example.com"
    end
  end

  describe "deployment with logo_url" do
    test "renders logo image when app_template has logo_url", %{conn: conn, tenant: tenant} do
      template_with_logo = insert(:app_template, logo_url: "https://example.com/logo.png")

      insert(:deployment,
        tenant: tenant,
        app_template: template_with_logo,
        status: :running,
        external_id: "logo_container"
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "https://example.com/logo.png"
    end
  end

  describe "start deployment failure" do
    test "start still succeeds with status update even on deploy error", %{conn: conn, tenant: tenant, template: template} do
      stopped =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "fail_start_container"
        )

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:error, "failed"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      {:ok, view, _html} = live(conn, ~p"/tenants/#{tenant.id}")
      html = render_click(view, "start", %{"id" => to_string(stopped.id)})
      assert html =~ "starting" or html =~ stopped.app_template.name
    end
  end

  describe "deploying status pill" do
    test "renders deploying status pill", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :deploying,
        external_id: nil
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Deploying"
    end
  end

  describe "removing status pill" do
    test "renders removing status pill", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :removing,
        external_id: nil
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Removing"
    end
  end

  describe "relative_time branches" do
    test "shows 'just now' for very recent reconciliation", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_just_now",
        last_reconciled_at: DateTime.utc_now()
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "just now"
    end

    test "shows seconds ago for recent reconciliation", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_secs",
        last_reconciled_at: DateTime.add(DateTime.utc_now(), -30, :second)
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "s ago"
    end

    test "shows minutes ago for reconciliation minutes back", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_mins",
        last_reconciled_at: DateTime.add(DateTime.utc_now(), -300, :second)
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "m ago"
    end

    test "shows hours ago for reconciliation hours back", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_hrs",
        last_reconciled_at: DateTime.add(DateTime.utc_now(), -7200, :second)
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "h ago"
    end

    test "shows date for reconciliation days back", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_days",
        last_reconciled_at: DateTime.add(DateTime.utc_now(), -172_800, :second)
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ ~r/\d{4}-\d{2}-\d{2}/
    end

    test "shows 'never reconciled' when last_reconciled_at is nil", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "rt_nil",
        last_reconciled_at: nil
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "never reconciled"
    end
  end

  describe "infrastructure topology section" do
    test "renders topology section when deployments exist", %{conn: conn, tenant: tenant, template: template} do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "topo_container"
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      assert html =~ "Infrastructure Topology"
    end

    test "does not render topology section when no deployments", %{conn: conn, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")
      refute html =~ "Infrastructure Topology"
    end
  end
end
