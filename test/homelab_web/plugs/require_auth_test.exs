defmodule HomelabWeb.Plugs.RequireAuthTest do
  use HomelabWeb.ConnCase, async: false

  alias HomelabWeb.Plugs.RequireAuth
  describe "when setup is not completed" do
    test "allows unauthenticated requests through", %{conn: conn} do
      Homelab.Settings.set("setup_completed", "false")

      conn =
        conn
        |> delete_session(:user_id)
        |> RequireAuth.call([])

      refute conn.halted
    end
  end

  describe "when setup is completed" do
    test "redirects to /auth/oidc when user_id is not in session", %{conn: conn} do
      conn =
        conn
        |> delete_session(:user_id)
        |> RequireAuth.call([])

      assert redirected_to(conn) == "/auth/oidc"
      assert conn.halted
    end

    test "redirects when user_id in session points to nonexistent user", %{conn: conn} do
      conn =
        conn
        |> put_session(:user_id, -1)
        |> RequireAuth.call([])

      assert redirected_to(conn) == "/auth/oidc"
      assert conn.halted
    end

    test "assigns current_user when user exists", %{conn: conn, user: user} do
      conn = RequireAuth.call(conn, [])
      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end
  end
end
