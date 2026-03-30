defmodule HomelabWeb.Plugs.RequireSetupTest do
  use HomelabWeb.ConnCase, async: false

  alias HomelabWeb.Plugs.RequireSetup

  describe "when setup is not completed" do
    setup %{conn: conn} do
      Homelab.Settings.set("setup_completed", "false")
      {:ok, conn: conn}
    end

    test "redirects non-setup paths to /setup", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/")
        |> RequireSetup.call([])

      assert redirected_to(conn) == "/setup"
      assert conn.halted
    end

    test "allows /setup path through", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/setup")
        |> RequireSetup.call([])

      refute conn.halted
    end

    test "allows /auth paths through", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/auth/oidc")
        |> RequireSetup.call([])

      refute conn.halted
    end
  end

  describe "when setup is completed" do
    test "redirects /setup to /", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/setup")
        |> RequireSetup.call([])

      assert redirected_to(conn) == "/"
      assert conn.halted
    end

    test "allows normal paths through", %{conn: conn} do
      conn =
        conn
        |> Map.put(:request_path, "/")
        |> RequireSetup.call([])

      refute conn.halted
    end
  end
end
