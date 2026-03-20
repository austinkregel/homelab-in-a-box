defmodule HomelabWeb.Api.V1.TenantControllerTest do
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/v1/tenants" do
    test "lists all tenants", %{conn: conn} do
      insert(:tenant, name: "Friends", slug: "friends")
      insert(:tenant, name: "Family", slug: "family")

      conn = get(conn, ~p"/api/v1/tenants")
      assert %{"data" => tenants} = json_response(conn, 200)
      assert length(tenants) == 2
    end

    test "returns empty list when no tenants", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants")
      assert %{"data" => []} = json_response(conn, 200)
    end
  end

  describe "POST /api/v1/tenants" do
    test "creates tenant with valid data", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/tenants", %{
          "tenant" => %{"name" => "My Friends", "slug" => "my-friends"}
        })

      assert %{"data" => tenant} = json_response(conn, 201)
      assert tenant["name"] == "My Friends"
      assert tenant["slug"] == "my-friends"
      assert tenant["status"] == "active"
    end

    test "returns 422 with invalid data", %{conn: conn} do
      conn =
        post(conn, ~p"/api/v1/tenants", %{
          "tenant" => %{"name" => "", "slug" => "A"}
        })

      assert %{"errors" => errors} = json_response(conn, 422)
      assert errors != %{}
    end
  end

  describe "GET /api/v1/tenants/:id" do
    test "returns tenant by id", %{conn: conn} do
      tenant = insert(:tenant, name: "Friends", slug: "friends")
      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}")

      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == tenant.id
      assert data["name"] == "Friends"
    end

    test "returns 404 for nonexistent tenant", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/tenants/999")
      assert json_response(conn, 404)
    end
  end

  describe "PATCH /api/v1/tenants/:id" do
    test "updates tenant", %{conn: conn} do
      tenant = insert(:tenant)

      conn =
        patch(conn, ~p"/api/v1/tenants/#{tenant.id}", %{
          "tenant" => %{"name" => "Updated Name"}
        })

      assert %{"data" => data} = json_response(conn, 200)
      assert data["name"] == "Updated Name"
    end
  end

  describe "DELETE /api/v1/tenants/:id" do
    test "deletes tenant", %{conn: conn} do
      tenant = insert(:tenant)
      conn = delete(conn, ~p"/api/v1/tenants/#{tenant.id}")
      assert response(conn, 204)
    end
  end
end
