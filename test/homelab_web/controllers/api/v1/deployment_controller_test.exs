defmodule HomelabWeb.Api.V1.DeploymentControllerTest do
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory

  setup %{conn: conn} do
    tenant = insert(:tenant)
    {:ok, conn: put_req_header(conn, "accept", "application/json"), tenant: tenant}
  end

  describe "GET /api/v1/tenants/:tenant_id/deployments" do
    test "lists deployments for tenant", %{conn: conn, tenant: tenant} do
      insert(:deployment, tenant: tenant)
      insert(:deployment, tenant: tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments")
      assert %{"data" => deployments} = json_response(conn, 200)
      assert length(deployments) == 2
    end

    test "does not include deployments from other tenants", %{conn: conn, tenant: tenant} do
      other_tenant = insert(:tenant)
      insert(:deployment, tenant: tenant)
      insert(:deployment, tenant: other_tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments")
      assert %{"data" => deployments} = json_response(conn, 200)
      assert length(deployments) == 1
    end
  end

  describe "POST /api/v1/tenants/:tenant_id/deployments" do
    test "creates deployment", %{conn: conn, tenant: tenant} do
      template = insert(:app_template)

      conn =
        post(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments", %{
          "deployment" => %{
            "app_template_id" => template.id,
            "domain" => "app.friends.homelab.local"
          }
        })

      assert %{"data" => deployment} = json_response(conn, 201)
      assert deployment["status"] == "pending"
      assert deployment["tenant_id"] == tenant.id
    end

    test "returns 422 with invalid data", %{conn: conn, tenant: tenant} do
      conn =
        post(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments", %{
          "deployment" => %{}
        })

      assert json_response(conn, 422)
    end
  end

  describe "GET /api/v1/tenants/:tenant_id/deployments/:id" do
    test "returns deployment", %{conn: conn, tenant: tenant} do
      deployment = insert(:deployment, tenant: tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments/#{deployment.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == deployment.id
    end

    test "returns 404 for deployment in different tenant", %{conn: conn, tenant: tenant} do
      other_tenant = insert(:tenant)
      deployment = insert(:deployment, tenant: other_tenant)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments/#{deployment.id}")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/tenants/:tenant_id/deployments/:id JSON rendering" do
    test "redacts sensitive env vars in response", %{conn: conn, tenant: tenant} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          env_overrides: %{
            "DB_PASSWORD" => "super-secret",
            "API_TOKEN" => "tok-123",
            "SECRET_KEY" => "key-456",
            "PRIVATE_KEY" => "pk-789",
            "PUBLIC_KEY" => "pub-abc",
            "NORMAL_VAR" => "visible"
          }
        )

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments/#{deployment.id}")
      assert %{"data" => data} = json_response(conn, 200)

      env = data["env_overrides"]
      assert env["DB_PASSWORD"] == "***REDACTED***"
      assert env["API_TOKEN"] == "***REDACTED***"
      assert env["SECRET_KEY"] == "***REDACTED***"
      assert env["PRIVATE_KEY"] == "***REDACTED***"
      assert env["PUBLIC_KEY"] == "pub-abc"
      assert env["NORMAL_VAR"] == "visible"
    end

    test "handles nil env_overrides", %{conn: conn, tenant: tenant} do
      deployment = insert(:deployment, tenant: tenant, env_overrides: nil)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments/#{deployment.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["env_overrides"] == %{}
    end
  end

  describe "DELETE /api/v1/tenants/:tenant_id/deployments/:id" do
    test "marks deployment for removal", %{conn: conn, tenant: tenant} do
      deployment = insert(:deployment, tenant: tenant, status: :running)

      conn = delete(conn, ~p"/api/v1/tenants/#{tenant.id}/deployments/#{deployment.id}")
      assert response(conn, 204)

      updated = Homelab.Repo.get!(Homelab.Deployments.Deployment, deployment.id)
      assert updated.status == :removing
    end
  end
end
