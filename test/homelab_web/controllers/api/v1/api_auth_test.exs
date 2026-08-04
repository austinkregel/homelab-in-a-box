defmodule HomelabWeb.Api.V1.ApiAuthTest do
  @moduledoc """
  The `/api/v1` scope had no authentication of any kind.

  Every other API test in this directory passed against the unprotected router, because
  `HomelabWeb.ConnCase` seeds `user_id` into the session for every test it builds — so
  the whole suite was authenticated by accident and could not observe that the routes
  were not. These tests build their conn WITHOUT a session on purpose.

  It mattered because the app's own Traefik rule matches `Host(base_domain)` with no path
  constraint, so all of this was reachable at `https://<base_domain>/api/v1/...`.
  """
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory

  # Deliberately NOT the `conn` from ConnCase — that one is already logged in.
  defp anonymous do
    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_req_header("accept", "application/json")
  end

  describe "unauthenticated access" do
    test "reading tenants is refused" do
      insert(:tenant)

      conn = get(anonymous(), ~p"/api/v1/tenants")

      assert json_response(conn, 401)
    end

    test "reading app templates is refused" do
      assert json_response(get(anonymous(), ~p"/api/v1/app-templates"), 401)
    end

    test "reading backups is refused" do
      tenant = insert(:tenant)
      assert json_response(get(anonymous(), ~p"/api/v1/tenants/#{tenant.id}/backups"), 401)
    end

    test "creating a deployment is refused" do
      # The one that mattered most: this reaches `deploy_now/1`, and `image_override`
      # accepts any parseable reference — so it was arbitrary-image execution on the
      # Docker host for anyone who could reach the domain.
      tenant = insert(:tenant)
      template = insert(:app_template)

      conn =
        post(anonymous(), ~p"/api/v1/tenants/#{tenant.id}/deployments", %{
          "deployment" => %{
            "app_template_id" => template.id,
            "image_override" => "attacker/whatever:latest"
          }
        })

      assert json_response(conn, 401)
      assert Homelab.Repo.aggregate(Homelab.Deployments.Deployment, :count) == 0
    end

    test "destroying a deployment is refused" do
      deployment = insert(:deployment)

      conn =
        delete(
          anonymous(),
          ~p"/api/v1/tenants/#{deployment.tenant_id}/deployments/#{deployment.id}"
        )

      assert json_response(conn, 401)
      assert Homelab.Repo.get(Homelab.Deployments.Deployment, deployment.id)
    end

    test "triggering a restore is refused" do
      job = insert(:backup_job)

      conn =
        post(
          anonymous(),
          ~p"/api/v1/tenants/#{job.deployment.tenant_id}/backups/#{job.id}/restore"
        )

      assert json_response(conn, 401)
    end

    test "the refusal is JSON, not a redirect to the login page" do
      # A 302 to /auth/oidc is not an answer a JSON client can act on — curl follows it
      # and reports 200 with an HTML body, so a script cannot tell denied from succeeded.
      conn = get(anonymous(), ~p"/api/v1/tenants")

      assert conn.status == 401
      assert %{"errors" => %{"detail" => "Unauthorized"}} = json_response(conn, 401)
    end
  end

  describe "health" do
    test "stays public — a container HEALTHCHECK runs before anyone can log in" do
      conn = get(anonymous(), ~p"/api/v1/health")

      assert %{"status" => "ok"} = json_response(conn, 200)
    end
  end

  describe "authenticated access" do
    test "a logged-in session still reaches the API", %{conn: conn} do
      insert(:tenant, name: "Friends", slug: "friends")

      conn = conn |> put_req_header("accept", "application/json") |> get(~p"/api/v1/tenants")

      assert %{"data" => [_tenant]} = json_response(conn, 200)
    end
  end
end
