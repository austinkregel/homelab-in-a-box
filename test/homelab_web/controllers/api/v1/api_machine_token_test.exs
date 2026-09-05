defmodule HomelabWeb.Api.V1.ApiMachineTokenTest do
  @moduledoc "`/api/v1` reached with a machine token instead of a browser session."
  # Not async: the settings and discovery caches are global ETS tables.
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory

  alias Homelab.Auth.MachineToken

  setup do
    bypass = Bypass.open()
    Homelab.Settings.set("oidc_issuer", "http://localhost:#{bypass.port}")
    MachineToken.reset_cache()

    Bypass.stub(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(
        200,
        Jason.encode!(%{
          "issuer" => "http://localhost:#{bypass.port}",
          "machine_info_endpoint" => "http://localhost:#{bypass.port}/api/machine-info",
          "grant_types_supported" => ["client_credentials"]
        })
      )
    end)

    on_exit(fn ->
      Homelab.Settings.delete("oidc_issuer")
      MachineToken.reset_cache()
    end)

    {:ok, bypass: bypass}
  end

  defp machine_info(bypass, status, body) do
    Bypass.stub(bypass, "GET", "/api/machine-info", fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.resp(status, Jason.encode!(body))
    end)
  end

  defp good_token(bypass) do
    machine_info(bypass, 200, %{
      "client_id" => "mcp-1",
      "name" => "MCP Server",
      "scopes" => ["openid", "homelab"]
    })
  end

  # No session: the token is the only credential.
  defp with_token(token) do
    unauthenticated_conn()
    |> put_req_header("accept", "application/json")
    |> put_req_header("authorization", "Bearer #{token}")
  end

  describe "reads" do
    test "a machine token can list tenants", %{bypass: bypass} do
      good_token(bypass)
      insert(:tenant)

      conn = get(with_token("tok"), ~p"/api/v1/tenants")

      assert %{"data" => [_ | _]} = json_response(conn, 200)
    end

    test "the scheme is matched case-insensitively", %{bypass: bypass} do
      good_token(bypass)

      conn =
        unauthenticated_conn()
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "bearer tok")
        |> get(~p"/api/v1/tenants")

      assert json_response(conn, 200)
    end

    test "the machine turns up in the roster as a :service row", %{bypass: bypass} do
      good_token(bypass)

      assert json_response(get(with_token("tok"), ~p"/api/v1/tenants"), 200)

      assert [%{role: :service, sub: "service:mcp-1", name: "MCP Server"}] =
               Homelab.Accounts.list_users() |> Enum.filter(&Homelab.Accounts.service?/1)
    end
  end

  describe "writes are refused" do
    test "creating a deployment is 403, not 200", %{bypass: bypass} do
      good_token(bypass)
      tenant = insert(:tenant)
      template = insert(:app_template)

      conn =
        post(with_token("tok"), ~p"/api/v1/tenants/#{tenant.id}/deployments", %{
          "deployment" => %{"app_template_id" => template.id, "image_override" => "evil:latest"}
        })

      assert json_response(conn, 403)
    end

    test "deleting a tenant is refused", %{bypass: bypass} do
      good_token(bypass)
      tenant = insert(:tenant)

      assert json_response(delete(with_token("tok"), ~p"/api/v1/tenants/#{tenant.id}"), 403)
      assert {:ok, _} = Homelab.Tenants.get_tenant(tenant.id)
    end
  end

  describe "refusals" do
    test "a token the issuer rejects is 401", %{bypass: bypass} do
      machine_info(bypass, 401, %{"error" => "invalid_token"})

      assert json_response(get(with_token("bad"), ~p"/api/v1/tenants"), 401)
    end

    test "a valid token without the required scope is 401", %{bypass: bypass} do
      machine_info(bypass, 200, %{"client_id" => "other", "scopes" => ["openid", "email"]})

      assert json_response(get(with_token("tok"), ~p"/api/v1/tenants"), 401)
    end

    test "a bad token is refused even alongside a good admin session", %{
      conn: conn,
      bypass: bypass,
      user: user
    } do
      assert user.role == :admin
      machine_info(bypass, 401, %{"error" => "invalid_token"})

      refused =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Bearer expired")
        |> get(~p"/api/v1/tenants")

      # The token decides once presented; falling back would let a lapsed agent act as the operator.
      assert json_response(refused, 401)
    end

    test "a malformed authorization header falls through to the session", %{conn: conn} do
      # Not a Bearer credential, so not a token being presented — the session still answers.
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> put_req_header("authorization", "Basic abc123")
        |> get(~p"/api/v1/tenants")

      assert json_response(conn, 200)
    end

    test "an unreachable issuer is 401, not 500", %{bypass: bypass} do
      Bypass.down(bypass)

      assert json_response(get(with_token("tok"), ~p"/api/v1/tenants"), 401)
    end
  end
end
