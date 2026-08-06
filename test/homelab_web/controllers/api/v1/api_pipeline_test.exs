defmodule HomelabWeb.Api.V1.ApiPipelineTest do
  @moduledoc """
  The `:api` pipeline must actually fetch the session.

  `Plug.Session` in the endpoint only REGISTERS a lazy fetcher; it does not fetch. The
  `:api` pipeline was `plug :accepts, ["json"]` and nothing else, so by the time
  `RequireAuthApi` asked `RequireAuth.current_user/1` who was logged in,
  `Plug.Conn.get_session/1` raised `ArgumentError, "session not fetched, call
  fetch_session/2"`. Every authenticated `/api/v1` request 500'd in production.

  The whole existing API suite missed it because `Phoenix.ConnTest.init_test_session/2`
  writes `:plug_session` into the conn's private map directly, marking the session as
  already fetched — so the pipeline's missing `:fetch_session` never mattered. Every conn
  in `HomelabWeb.ConnCase` goes through it, including `api_auth_test.exs`, which was
  written specifically to prove the API is authenticated.

  So these tests build their conn from `Phoenix.ConnTest.build_conn/0` and NOTHING else.
  That is the only way the router's plug chain is the thing under test. Do not add
  `init_test_session/2` here — it would restore exactly the blind spot this file exists
  to close.
  """
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory

  @breakglass_token String.duplicate("p", 32)

  # No `init_test_session/2`: the session must be fetched by the pipeline or not at all.
  defp raw_conn do
    Phoenix.ConnTest.build_conn()
    |> put_req_header("accept", "application/json")
  end

  defp arm_breakglass do
    path = Path.join(System.tmp_dir!(), "api-pipeline-bg-#{System.unique_integer([:positive])}")
    File.write!(path, @breakglass_token)
    Application.put_env(:homelab, :breakglass, token_file: path, user: "api-pipeline")
    Application.put_env(:homelab, :breakglass_deny_delay_ms, 0)

    on_exit(fn ->
      Application.delete_env(:homelab, :breakglass)
      Application.delete_env(:homelab, :breakglass_deny_delay_ms)
      File.rm(path)
    end)
  end

  describe "the :api pipeline fetches the session" do
    test "an anonymous request is refused with 401, not a 500" do
      insert(:tenant)

      conn = get(raw_conn(), ~p"/api/v1/tenants")

      assert conn.status == 401
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end

    test "a real session cookie authenticates an API request" do
      # Sign in through the real browser pipeline so the cookie is minted by
      # `Plug.Session` the way a client actually gets one, then carry it to the API.
      # Break-glass is the only login that does not need an OIDC provider on the wire.
      arm_breakglass()
      insert(:tenant, name: "Friends", slug: "friends")

      logged_in =
        Phoenix.ConnTest.build_conn()
        |> Plug.Conn.put_private(:plug_skip_csrf_protection, true)
        |> post("/auth/break-glass", %{"token" => @breakglass_token})

      assert redirected_to(logged_in) == "/"
      assert [_ | _] = Map.keys(logged_in.resp_cookies)

      # `recycle/1` carries the response cookies into the next request, which is exactly
      # what a browser does — and the API pipeline has to fetch them itself.
      conn =
        logged_in
        |> Phoenix.ConnTest.recycle()
        |> put_req_header("accept", "application/json")
        |> get(~p"/api/v1/tenants")

      assert %{"data" => [_tenant]} = json_response(conn, 200)
      assert conn.assigns.current_user.role == :admin
    end

    test "health stays reachable without a session" do
      conn = get(raw_conn(), ~p"/api/v1/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end
end
