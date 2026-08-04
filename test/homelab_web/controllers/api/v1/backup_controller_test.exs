defmodule HomelabWeb.Api.V1.BackupControllerTest do
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory
  import Mox

  setup :verify_on_exit!

  # Backups moved under `/api/v1/tenants/:tenant_id/...` — the top-level routes listed
  # and restored across every tenant. These tests keep asserting the same behaviours;
  # they just have to name the tenant now. Cross-tenant refusal is covered separately in
  # `backup_tenant_scope_test.exs`.
  setup %{conn: conn} do
    tenant = insert(:tenant)
    deployment = insert(:deployment, tenant: tenant)

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     tenant: tenant,
     deployment: deployment}
  end

  describe "GET /api/v1/tenants/:tenant_id/backups" do
    test "lists the tenant's backup jobs", %{conn: conn, tenant: tenant, deployment: deployment} do
      insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/backups")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end

  describe "GET /api/v1/tenants/:tenant_id/backups/:id" do
    test "returns backup job by id", %{conn: conn, tenant: tenant, deployment: deployment} do
      job = insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/backups/#{job.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id
      assert data["status"] == "pending"
    end

    test "returns 404 for nonexistent job", %{conn: conn, tenant: tenant} do
      conn = get(conn, ~p"/api/v1/tenants/#{tenant.id}/backups/999")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/tenants/:tenant_id/backups" do
    test "creates a backup job", %{conn: conn, tenant: tenant, deployment: deployment} do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      conn =
        post(conn, ~p"/api/v1/tenants/#{tenant.id}/backups", %{
          "backup" => %{
            "deployment_id" => deployment.id,
            "scheduled_at" => now
          }
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["status"] == "pending"
      assert data["deployment_id"] == deployment.id
    end
  end

  describe "POST /api/v1/tenants/:tenant_id/backups/:id/restore" do
    test "restores a backup job", %{conn: conn, tenant: tenant, deployment: deployment} do
      job =
        insert(:backup_job,
          deployment: deployment,
          status: :completed,
          snapshot_id: "snap-abc123"
        )

      Homelab.Mocks.BackupProvider
      |> expect(:restore, fn "snap-abc123", "/data/restore" -> :ok end)

      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/backups/#{job.id}/restore")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id
    end

    test "returns 404 for nonexistent backup", %{conn: conn, tenant: tenant} do
      conn = post(conn, ~p"/api/v1/tenants/#{tenant.id}/backups/99999/restore")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/tenants/:tenant_id/backups with deployment_id filter" do
    test "filters backup jobs by deployment", %{
      conn: conn,
      tenant: tenant,
      deployment: deployment1
    } do
      deployment2 = insert(:deployment, tenant: tenant)
      insert(:backup_job, deployment: deployment1)
      insert(:backup_job, deployment: deployment2)

      conn =
        get(conn, ~p"/api/v1/tenants/#{tenant.id}/backups?deployment_id=#{deployment1.id}")

      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end
end
