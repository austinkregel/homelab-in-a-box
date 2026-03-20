defmodule HomelabWeb.Api.V1.AppTemplateControllerTest do
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/v1/app-templates" do
    test "lists all templates", %{conn: conn} do
      insert(:app_template, slug: "nextcloud", name: "Nextcloud")
      insert(:app_template, slug: "jellyfin", name: "Jellyfin")

      conn = get(conn, ~p"/api/v1/app-templates")
      assert %{"data" => templates} = json_response(conn, 200)
      assert length(templates) == 2
    end
  end

  describe "GET /api/v1/app-templates/:id" do
    test "returns template by id", %{conn: conn} do
      template = insert(:app_template, slug: "nextcloud", name: "Nextcloud")
      conn = get(conn, ~p"/api/v1/app-templates/#{template.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["slug"] == "nextcloud"
      assert data["name"] == "Nextcloud"
      assert data["exposure_mode"] == "sso_protected"
    end

    test "returns 404 for nonexistent template", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/app-templates/999")
      assert json_response(conn, 404)
    end
  end
end
