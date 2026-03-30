defmodule HomelabWeb.AuthControllerTest do
  use HomelabWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import Mox

  setup :verify_on_exit!

  defp setup_oidc_bypass(_context) do
    bypass = Bypass.open()
    url = "http://localhost:#{bypass.port}"

    Homelab.Settings.set("oidc_issuer", url)
    Homelab.Settings.set("oidc_client_id", "test-client")
    Homelab.Settings.set("oidc_client_secret", "test-secret")

    {:ok, bypass: bypass, oidc_url: url}
  end

  defp stub_discovery(bypass, url) do
    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(200, Jason.encode!(%{
        "issuer" => url,
        "authorization_endpoint" => "#{url}/authorize",
        "token_endpoint" => "#{url}/token",
        "userinfo_endpoint" => "#{url}/userinfo"
      }))
    end)
  end

  describe "GET /auth/oidc (login)" do
    test "redirects to setup when OIDC is not configured", %{conn: conn} do
      Homelab.Settings.delete("oidc_issuer")
      Homelab.Settings.delete("oidc_client_id")

      conn = get(conn, "/auth/oidc")
      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    test "redirects to setup when only issuer is set", %{conn: conn} do
      Homelab.Settings.set("oidc_issuer", "https://example.com")
      Homelab.Settings.delete("oidc_client_id")

      conn = get(conn, "/auth/oidc")
      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    test "redirects to setup when only client_id is set", %{conn: conn} do
      Homelab.Settings.delete("oidc_issuer")
      Homelab.Settings.set("oidc_client_id", "test-client")

      conn = get(conn, "/auth/oidc")
      assert redirected_to(conn) == "/setup"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "not configured"
    end

    setup :setup_oidc_bypass

    test "redirects to OIDC provider when configured", %{conn: conn, bypass: bypass, oidc_url: url} do
      stub_discovery(bypass, url)

      conn = get(conn, "/auth/oidc")
      location = redirected_to(conn, 302)
      assert location =~ "authorize"
      assert location =~ "client_id=test-client"
      assert location =~ "response_type=code"
      assert location =~ "scope="
      assert location =~ "state="
    end

    test "stores oidc_state in session on redirect", %{conn: conn, bypass: bypass, oidc_url: url} do
      stub_discovery(bypass, url)

      conn = get(conn, "/auth/oidc")
      assert get_session(conn, :oidc_state) != nil
    end

    test "redirects to / when OIDC discovery fails", %{conn: conn, bypass: bypass} do
      Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      conn = get(conn, "/auth/oidc")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to discover"
    end
  end

  describe "GET /auth/oidc/callback" do
    test "rejects callback with missing code/state", %{conn: conn} do
      conn = get(conn, "/auth/oidc/callback")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing code"
    end

    test "rejects callback with only code (no state)", %{conn: conn} do
      conn = get(conn, "/auth/oidc/callback", %{"code" => "abc"})
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Missing code"
    end

    test "rejects callback with invalid state", %{conn: conn} do
      conn =
        conn
        |> put_session(:oidc_state, "expected-state")
        |> get("/auth/oidc/callback", %{"code" => "abc", "state" => "wrong-state"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid state"
    end

    test "rejects callback with nil session state", %{conn: conn} do
      conn = get(conn, "/auth/oidc/callback", %{"code" => "abc", "state" => "some-state"})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Invalid state"
    end

    setup :setup_oidc_bypass

    test "successful OIDC flow creates user and redirects", %{conn: conn, bypass: bypass, oidc_url: url} do
      state = "test-state-value"
      stub_discovery(bypass, url)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "test-access-token",
          "token_type" => "Bearer"
        }))
      end)

      Bypass.expect_once(bypass, "GET", "/userinfo", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "sub" => "oidc-callback-test-sub",
          "email" => "callback@test.com",
          "name" => "Callback User"
        }))
      end)

      conn =
        conn
        |> put_session(:oidc_state, state)
        |> get("/auth/oidc/callback", %{"code" => "auth-code", "state" => state})

      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed in"
      assert get_session(conn, :user_id) != nil
      assert get_session(conn, :oidc_state) == nil
    end

    test "redirects with error when discovery fails during callback", %{conn: conn, bypass: bypass} do
      state = "test-state"

      Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        Plug.Conn.resp(conn, 500, "Internal Server Error")
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_session(:oidc_state, state)
            |> get("/auth/oidc/callback", %{"code" => "auth-code", "state" => state})

          assert redirected_to(conn) == "/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to discover"
        end)

      assert log =~ "OIDC discovery failed for http://localhost:#{bypass.port}: {:http_error, 500}"
    end

    test "redirects with error when token exchange returns non-200", %{conn: conn, bypass: bypass, oidc_url: url} do
      state = "test-state"
      stub_discovery(bypass, url)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(400, Jason.encode!(%{
          "error" => "invalid_grant",
          "error_description" => "Code has expired"
        }))
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_session(:oidc_state, state)
            |> get("/auth/oidc/callback", %{"code" => "bad-code", "state" => state})

          assert redirected_to(conn) == "/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to exchange code"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "invalid_grant"
        end)

      assert log =~ "OIDC token endpoint returned 400:"
      assert log =~ "invalid_grant"
      assert log =~ "OIDC token exchange failed: {:token_error, 400,"
    end

    test "redirects with error when token exchange returns non-200 with plain body", %{conn: conn, bypass: bypass, oidc_url: url} do
      state = "test-state"
      stub_discovery(bypass, url)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("text/plain")
        |> Plug.Conn.resp(500, "Something went wrong")
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_session(:oidc_state, state)
            |> get("/auth/oidc/callback", %{"code" => "bad-code", "state" => state})

          assert redirected_to(conn) == "/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to exchange code"
        end)

      assert log =~ "OIDC token endpoint returned 500:"
      assert log =~ "OIDC token exchange failed: {:token_error, 500,"
    end

    test "redirects with error when token exchange returns non-200 with error key only", %{conn: conn, bypass: bypass, oidc_url: url} do
      state = "test-state"
      stub_discovery(bypass, url)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(401, Jason.encode!(%{"error" => "unauthorized_client"}))
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_session(:oidc_state, state)
            |> get("/auth/oidc/callback", %{"code" => "bad-code", "state" => state})

          assert redirected_to(conn) == "/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "unauthorized_client"
        end)

      assert log =~ "OIDC token endpoint returned 401:"
      assert log =~ "unauthorized_client"
      assert log =~ "OIDC token exchange failed: {:token_error, 401,"
    end

    test "redirects with error when userinfo fetch fails", %{conn: conn, bypass: bypass, oidc_url: url} do
      state = "test-state"
      stub_discovery(bypass, url)

      Bypass.expect_once(bypass, "POST", "/token", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{
          "access_token" => "test-access-token",
          "token_type" => "Bearer"
        }))
      end)

      Bypass.expect_once(bypass, "GET", "/userinfo", fn conn ->
        Plug.Conn.resp(conn, 401, "Unauthorized")
      end)

      log =
        capture_log(fn ->
          conn =
            conn
            |> put_session(:oidc_state, state)
            |> get("/auth/oidc/callback", %{"code" => "auth-code", "state" => state})

          assert redirected_to(conn) == "/"
          assert Phoenix.Flash.get(conn.assigns.flash, :error) =~ "Failed to fetch user info"
        end)

      assert log =~ "OIDC userinfo fetch failed: {:http_error, 401}"
    end
  end

  describe "GET /auth/logout" do
    test "clears session and redirects", %{conn: conn} do
      conn = get(conn, "/auth/logout")
      assert redirected_to(conn) == "/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Signed out"
    end
  end
end
