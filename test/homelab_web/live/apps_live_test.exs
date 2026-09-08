defmodule HomelabWeb.AppsLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    media = insert(:tenant, name: "Media", slug: "media")
    dev = insert(:tenant, name: "Development", slug: "development")

    jelly = insert(:app_template, name: "Jellyfin", image: "jellyfin/jellyfin")
    sonarr = insert(:app_template, name: "Sonarr", image: "linuxserver/sonarr")

    running = insert(:deployment, tenant: media, app_template: jelly, status: :running)
    failed = insert(:deployment, tenant: dev, app_template: sonarr, status: :failed)

    {:ok, conn: conn, media: media, dev: dev, running: running, failed: failed}
  end

  describe "listing" do
    test "shows every deployment across every space", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/apps")

      assert html =~ "Jellyfin"
      assert html =~ "Sonarr"
      assert html =~ "Media"
      assert html =~ "Development"
    end

    test "sorts what needs attention first", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/apps")

      # Sonarr is failed and Jellyfin is running, so Sonarr leads despite the alphabet.
      assert :binary.match(html, "Sonarr") < :binary.match(html, "Jellyfin")
    end

    test "shows the error message of a failed deployment", %{conn: conn, failed: failed} do
      {:ok, _} = Homelab.Deployments.update_status(failed, :failed, error: "image pull failed")

      {:ok, _view, html} = live(conn, ~p"/apps")

      assert html =~ "image pull failed"
    end
  end

  describe "search" do
    test "filters by app name", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/apps?q=jelly")

      assert html =~ "Jellyfin"
      refute html =~ "Sonarr"
    end

    test "filters by space name", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/apps?q=development")

      assert html =~ "Sonarr"
      refute html =~ "Jellyfin"
    end

    test "typing a query patches the URL", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/apps")

      render_change(view, "search", %{"q" => "sonarr"})

      assert_patched(view, ~p"/apps?q=sonarr")
    end

    test "a query matching nothing explains itself", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/apps?q=zzzznope")

      assert html =~ "Nothing matches"
    end
  end

  describe "space filter" do
    test "narrows to one space", %{conn: conn, media: media} do
      {:ok, _view, html} = live(conn, ~p"/apps?space=#{media.id}")

      assert html =~ "Jellyfin"
      refute html =~ "Sonarr"
    end

    test "clicking a space chip patches the URL", %{conn: conn, media: media} do
      {:ok, view, _html} = live(conn, ~p"/apps")

      render_click(view, "filter_space", %{"id" => to_string(media.id)})

      assert_patched(view, ~p"/apps?space=#{media.id}")
    end
  end
end
