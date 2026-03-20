defmodule HomelabWeb.TenantLiveTest do
  use HomelabWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Homelab.Factory

  describe "TenantLive" do
    test "renders tenant detail page", %{conn: conn} do
      tenant = insert(:tenant, name: "Friends Space", slug: "friends")

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")

      assert html =~ "Friends Space"
      assert html =~ "friends"
      assert html =~ "Deploy App"
    end

    test "shows deployments for the tenant", %{conn: conn} do
      tenant = insert(:tenant, name: "Friends Space")
      template = insert(:app_template, name: "Nextcloud")

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        domain: "nc.friends.local"
      )

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")

      assert html =~ "Nextcloud"
      assert html =~ "Running"
      assert html =~ "nc.friends.local"
    end

    test "shows empty state when no deployments", %{conn: conn} do
      tenant = insert(:tenant)

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")

      assert html =~ "No apps deployed yet"
      assert html =~ "Visit the catalog to deploy your first app"
    end

    test "redirects for nonexistent tenant", %{conn: conn} do
      {:error, {:redirect, %{to: "/", flash: %{"error" => "Tenant not found"}}}} =
        live(conn, ~p"/tenants/99999")
    end

    test "deploy app link navigates to catalog", %{conn: conn} do
      tenant = insert(:tenant)

      {:ok, _view, html} = live(conn, ~p"/tenants/#{tenant.id}")

      assert html =~ ~p"/catalog"
    end
  end
end
