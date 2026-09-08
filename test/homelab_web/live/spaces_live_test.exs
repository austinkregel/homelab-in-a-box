defmodule HomelabWeb.SpacesLiveTest do
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

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn}
  end

  test "lists every space with its app count", %{conn: conn} do
    media = insert(:tenant, name: "Media", slug: "media")
    insert(:deployment, tenant: media, status: :running)

    {:ok, _view, html} = live(conn, ~p"/spaces")

    assert html =~ "Media"
    assert html =~ "media"
    assert html =~ "1 running"
  end

  test "shows spaces the sidebar hides", %{conn: conn} do
    insert(:tenant, name: "Retired", slug: "retired", status: :suspended)

    {:ok, _view, html} = live(conn, ~p"/spaces")

    assert html =~ "Retired"
    assert html =~ "suspended"
  end

  test "explains itself when there are no spaces", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/spaces")

    assert html =~ "No spaces yet"
  end

  test "creates a space", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/spaces")

    render_click(view, "open_create", %{})

    html =
      render_submit(view, "save_space", %{
        "tenant" => %{"name" => "Identity", "slug" => "identity"}
      })

    assert html =~ "Identity"
    assert Enum.any?(Homelab.Tenants.list_tenants(), &(&1.slug == "identity"))
  end

  test "reports an invalid slug instead of creating", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/spaces")

    render_click(view, "open_create", %{})

    html =
      render_submit(view, "save_space", %{"tenant" => %{"name" => "Bad", "slug" => "-nope-"}})

    assert html =~ "must be lowercase alphanumeric"
    assert Homelab.Tenants.list_tenants() == []
  end
end
