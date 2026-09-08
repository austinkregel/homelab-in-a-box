defmodule HomelabWeb.BreakGlassControllerTest do
  use HomelabWeb.ConnCase, async: false

  import ExUnit.CaptureLog

  alias Homelab.Accounts
  alias Homelab.Audit

  @token String.duplicate("b", 32)

  # A conn with a live session but NO logged-in user — break-glass is the path in
  # when you have no identity yet.
  defp anon_conn do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    # The break-glass form carries a real CSRF token in the browser; in tests we
    # post directly, so skip the forgery check the browser pipeline enforces.
    |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
  end

  # Arms break-glass by writing a token file, and returns the path so tests can
  # assert it is consumed. Pass token: nil to configure a path with no file (the
  # "disabled" case).
  defp arm_breakglass(opts \\ []) do
    path = Path.join(System.tmp_dir!(), "bg-token-#{System.unique_integer([:positive])}")

    case Keyword.get(opts, :token, @token) do
      nil -> :ok
      token -> File.write!(path, token)
    end

    Application.put_env(:homelab, :breakglass,
      token_file: path,
      user: Keyword.get(opts, :user, "breakglass")
    )

    # Skip the anti-brute-force sleep in tests.
    Application.put_env(:homelab, :breakglass_deny_delay_ms, 0)

    on_exit(fn ->
      Application.delete_env(:homelab, :breakglass)
      Application.delete_env(:homelab, :breakglass_deny_delay_ms)
      File.rm(path)
    end)

    path
  end

  describe "when break-glass is not armed" do
    test "GET 404s when the token file is absent" do
      arm_breakglass(token: nil)
      conn = get(anon_conn(), "/auth/break-glass")
      assert conn.status == 404
    end

    test "POST 404s when the token file is absent" do
      arm_breakglass(token: nil)
      conn = post(anon_conn(), "/auth/break-glass", %{"token" => @token})
      assert conn.status == 404
    end

    test "a token shorter than the minimum keeps the feature disabled (404)" do
      arm_breakglass(token: "too-short")
      conn = get(anon_conn(), "/auth/break-glass")
      assert conn.status == 404
    end
  end

  describe "when break-glass is armed" do
    setup do
      {:ok, path: arm_breakglass()}
    end

    test "GET renders the token form" do
      conn = get(anon_conn(), "/auth/break-glass")
      assert conn.status == 200
      assert conn.resp_body =~ "Break-glass sign in"
      assert conn.resp_body =~ ~s(name="token")
      assert conn.resp_body =~ ~s(name="_csrf_token")
    end

    test "correct token signs in, creates an admin, audits, and consumes the file", %{path: path} do
      {conn, log} =
        with_log(fn -> post(anon_conn(), "/auth/break-glass", %{"token" => @token}) end)

      # A break-glass grant is the loudest thing this app can do; the log line is
      # part of the feature, not noise, so it is asserted rather than silenced.
      assert log =~ "BREAK-GLASS login SUCCEEDED"
      assert log =~ "BREAK-GLASS: token consumed"

      assert redirected_to(conn) == "/"
      user_id = get_session(conn, :user_id)
      assert user_id

      user = Accounts.get_user(user_id)
      assert user.role == :admin
      assert user.sub == "breakglass:breakglass"

      assert Enum.any?(Audit.list_recent(10), &(&1.action == "break_glass.login"))
      # One-time: the token file is gone after a successful login.
      refute File.exists?(path)
    end

    test "the token cannot be reused — a second attempt 404s" do
      {c1, log} =
        with_log(fn -> post(anon_conn(), "/auth/break-glass", %{"token" => @token}) end)

      assert redirected_to(c1) == "/"
      assert log =~ "BREAK-GLASS: token consumed"

      c2 = post(anon_conn(), "/auth/break-glass", %{"token" => @token})
      assert c2.status == 404
      assert get_session(c2, :user_id) == nil
    end

    test "wrong token is rejected, leaves the file intact, and audits the denial", %{path: path} do
      {conn, log} =
        with_log(fn ->
          post(anon_conn(), "/auth/break-glass", %{"token" => "wrong-but-long-enough-token-xxx"})
        end)

      assert log =~ "BREAK-GLASS login DENIED"
      assert conn.status == 401
      assert conn.resp_body =~ "Invalid break-glass token"
      assert get_session(conn, :user_id) == nil
      assert Enum.any?(Audit.list_recent(10), &(&1.action == "break_glass.denied"))
      # A failed guess must NOT consume the token (no lockout of the operator).
      assert File.exists?(path)
    end

    test "missing token is rejected and leaves the file intact", %{path: path} do
      {conn, log} = with_log(fn -> post(anon_conn(), "/auth/break-glass", %{}) end)

      assert log =~ "BREAK-GLASS login DENIED"
      assert conn.status == 401
      assert get_session(conn, :user_id) == nil
      assert File.exists?(path)
    end
  end
end
