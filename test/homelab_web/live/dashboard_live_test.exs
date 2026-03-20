defmodule HomelabWeb.DashboardLiveTest do
  use HomelabWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Homelab.Factory

  describe "DashboardLive" do
    test "renders dashboard with stats", %{conn: conn} do
      tenant = insert(:tenant, name: "Friends Space", slug: "friends")
      template = insert(:app_template, name: "Nextcloud")

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        domain: "nc.example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Dashboard"
      assert html =~ "self-hosted infrastructure"
      assert html =~ "Friends Space"
      assert html =~ "friends"
    end

    test "displays deployment counts", %{conn: conn} do
      tenant = insert(:tenant)
      template = insert(:app_template)
      insert(:deployment, tenant: tenant, app_template: template, status: :running)

      template2 = insert(:app_template, slug: "app2", name: "App Two")
      insert(:deployment, tenant: tenant, app_template: template2, status: :failed)

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Deployments"
      assert html =~ "Running"
      assert html =~ "Failed"
    end

    test "displays recent deployments table", %{conn: conn} do
      tenant = insert(:tenant, name: "Test Tenant")
      template = insert(:app_template, name: "TestApp")

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        domain: "test.example.com"
      )

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Recent Deployments"
      assert html =~ "TestApp"
      assert html =~ "Test Tenant"
      assert html =~ "test.example.com"
    end

    test "shows empty state when no data exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ "Dashboard"
      assert html =~ "Spaces"
      assert html =~ "Deployments"
    end

    test "tenant names link to tenant detail page", %{conn: conn} do
      tenant = insert(:tenant, name: "My Space")

      {:ok, _view, html} = live(conn, ~p"/")

      assert html =~ ~p"/tenants/#{tenant.id}"
      assert html =~ "My Space"
    end
  end
end
