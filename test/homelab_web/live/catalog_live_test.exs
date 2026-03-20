defmodule HomelabWeb.CatalogLiveTest do
  use HomelabWeb.ConnCase, async: true

  import Phoenix.LiveViewTest
  import Homelab.Factory

  describe "CatalogLive" do
    setup %{conn: conn} do
      user = insert(:user)
      conn = log_in_user(conn, user)
      %{conn: conn}
    end

    test "renders catalog page with tabs", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/catalog")

      assert html =~ "App Catalog"
      assert html =~ "Curated"
      assert html =~ "Search"
      assert html =~ "Custom"
    end

    test "shows custom tab form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      view
      |> element("button", "Custom")
      |> render_click()

      assert render(view) =~ "Image"
      assert render(view) =~ "Tag"
      assert render(view) =~ "Display name"
    end

    test "custom deploy opens deploy modal", %{conn: conn} do
      _tenant = insert(:tenant, name: "Friends", slug: "friends")

      {:ok, view, _html} = live(conn, ~p"/catalog")

      view
      |> element("button", "Custom")
      |> render_click()

      view
      |> form("#custom-deploy-form", %{
        "image" => "nginx",
        "tag" => "latest",
        "name" => "My Nginx"
      })
      |> render_submit()

      assert render(view) =~ "Deploy My Nginx"
      assert render(view) =~ "Select a space..."
      assert render(view) =~ "Friends (friends)"
    end

    test "closing deploy modal hides it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      view
      |> element("button", "Custom")
      |> render_click()

      view
      |> form("#custom-deploy-form", %{
        "image" => "nginx",
        "tag" => "latest",
        "name" => "Test App"
      })
      |> render_submit()

      view
      |> element("button", "Cancel")
      |> render_click()

      refute render(view) =~ "Deploy Test App"
    end

    test "deploy modal displays exposure mode badge", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/catalog")

      view
      |> element("button", "Custom")
      |> render_click()

      view
      |> form("#custom-deploy-form", %{
        "image" => "nginx",
        "tag" => "latest",
        "name" => "Test App"
      })
      |> render_submit()

      # Custom templates get default exposure_mode :sso_protected -> "SSO"
      assert render(view) =~ "Deploy Test App"
      assert render(view) =~ "SSO"
    end
  end
end
