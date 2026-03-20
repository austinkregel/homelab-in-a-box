defmodule HomelabWeb.Api.V1.HealthControllerTest do
  use HomelabWeb.ConnCase, async: true

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/v1/health" do
    test "returns health status", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert %{"status" => "ok", "services" => services} = json_response(conn, 200)
      assert services["database"] == "ok"
    end

    test "includes version information", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/health")
      assert %{"version" => version} = json_response(conn, 200)
      assert is_binary(version)
    end
  end
end
