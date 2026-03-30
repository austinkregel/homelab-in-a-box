defmodule HomelabWeb.Live.HooksTest do
  use HomelabWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  describe "require_auth hook" do
    test "allows access to protected route when logged in", %{conn: conn} do
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)
      |> stub(:driver_id, fn -> "docker" end)
      |> stub(:display_name, fn -> "Docker" end)

      Homelab.Mocks.Gateway
      |> stub(:driver_id, fn -> "traefik" end)
      |> stub(:display_name, fn -> "Traefik" end)

      {:ok, _view, html} = live(conn, ~p"/catalog")
      assert html =~ "Catalog" or html =~ "catalog"
    end
  end

  describe "redirect_if_setup_done hook" do
    test "redirects /setup to / when setup is already complete", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup")
    end
  end
end
