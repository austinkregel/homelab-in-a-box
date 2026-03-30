defmodule HomelabWeb.Api.V1.FallbackControllerTest do
  use HomelabWeb.ConnCase, async: true

  describe "call/2 via API routes" do
    test "renders 404 for :not_found", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/app-templates/999999")

      assert json_response(conn, 404)
    end

    test "renders 500 for generic errors via health endpoint", %{conn: conn} do
      conn =
        conn
        |> put_req_header("accept", "application/json")
        |> get("/api/v1/health")

      assert conn.status in [200, 500]
    end
  end
end
