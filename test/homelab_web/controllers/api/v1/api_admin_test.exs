defmodule HomelabWeb.Api.V1.ApiAdminTest do
  @moduledoc """
  The mutating half of `/api/v1` is administrators-only; the reads are not.

  Sibling of `api_auth_test.exs`, one rung up. That file exists because every conn from
  `HomelabWeb.ConnCase` is signed in, so nine API test files were authenticated by
  accident and none could see that the routes were unprotected. The same trap is set
  again for roles: `test/support/factory.ex` defaults `role: :admin`, so every
  `insert(:user)` in the suite is an administrator, and nothing that uses the ConnCase
  conn can observe a member being refused.

  So these build their own conn around a real `:member`.

  Why writes and not reads: `POST /tenants/:id/deployments` reaches `deploy_now/1` and
  `image_override` accepts any parseable reference, so a write is arbitrary-image
  execution on the Docker host. `DELETE` destroys real infrastructure. `restore`
  overwrites live data from a snapshot. Listing what is deployed does none of that, and
  gating reads too would leave a member unable to use the box at all.
  """
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory

  defp as(role) do
    user = insert(:user, role: role)
    assert user.role == role

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> put_session(:user_id, user.id)
    |> put_req_header("accept", "application/json")
  end

  describe "a member" do
    test "cannot create a deployment" do
      # The one that matters most: arbitrary-image execution on the Docker host.
      tenant = insert(:tenant)
      template = insert(:app_template)

      conn =
        post(as(:member), ~p"/api/v1/tenants/#{tenant.id}/deployments", %{
          "deployment" => %{
            "app_template_id" => template.id,
            "image_override" => "attacker/whatever:latest"
          }
        })

      assert %{"errors" => %{"detail" => "Forbidden"}} = json_response(conn, 403)
      assert Homelab.Repo.aggregate(Homelab.Deployments.Deployment, :count) == 0
    end

    test "cannot destroy a deployment" do
      deployment = insert(:deployment)

      conn =
        delete(
          as(:member),
          ~p"/api/v1/tenants/#{deployment.tenant_id}/deployments/#{deployment.id}"
        )

      assert json_response(conn, 403)
      assert Homelab.Repo.get(Homelab.Deployments.Deployment, deployment.id)
    end

    test "cannot destroy a tenant" do
      tenant = insert(:tenant)

      conn = delete(as(:member), ~p"/api/v1/tenants/#{tenant.id}")

      assert json_response(conn, 403)
      assert Homelab.Repo.get(Homelab.Tenants.Tenant, tenant.id)
    end

    test "cannot trigger a restore" do
      job = insert(:backup_job, status: :completed, snapshot_id: "snap-1")

      # No Mox `expect` on the provider: a 403 that still ran the restore would be
      # worthless, and an unexpected call fails the test.
      conn =
        post(
          as(:member),
          ~p"/api/v1/tenants/#{job.deployment.tenant_id}/backups/#{job.id}/restore"
        )

      assert json_response(conn, 403)
    end

    test "CAN read" do
      # The other half. A gate that refuses everyone passes a refusal-only test, and
      # locking members out of reads is the failure this split was chosen to avoid.
      insert(:tenant, name: "Friends", slug: "friends")

      assert %{"data" => [_]} = json_response(get(as(:member), ~p"/api/v1/tenants"), 200)
      assert %{"data" => _} = json_response(get(as(:member), ~p"/api/v1/app-templates"), 200)
    end
  end

  describe "an administrator" do
    test "can do the thing the member was refused" do
      # Proves the 403s above are about the ROLE, not a broken route.
      tenant = insert(:tenant)

      conn = delete(as(:admin), ~p"/api/v1/tenants/#{tenant.id}")

      assert conn.status in [200, 204]
      refute Homelab.Repo.get(Homelab.Tenants.Tenant, tenant.id)
    end
  end

  describe "the refusal" do
    test "is 403, not 401 — and not a redirect" do
      # 401 would invite a client to go and re-authenticate as though that would help;
      # the caller already proved who they are. And a 302 to "/" is not an answer a JSON
      # client can act on: curl follows it and reports 200 with an HTML body.
      tenant = insert(:tenant)

      conn = delete(as(:member), ~p"/api/v1/tenants/#{tenant.id}")

      assert conn.status == 403
      assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
    end
  end
end
