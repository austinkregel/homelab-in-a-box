defmodule HomelabWeb.Api.V1.BackupControllerTest do
  # Not async: the backup destination is configured through Settings, whose cache is
  # process-independent.
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory

  alias Homelab.BackupTarget

  # Backups moved under `/api/v1/spaces/:space_id/...` — the top-level routes listed
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

  describe "GET /api/v1/spaces/:space_id/backups" do
    test "lists the tenant's backup jobs", %{conn: conn, tenant: tenant, deployment: deployment} do
      insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/spaces/#{tenant.id}/backups")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end

  describe "GET /api/v1/spaces/:space_id/backups/:id" do
    test "returns backup job by id", %{conn: conn, tenant: tenant, deployment: deployment} do
      job = insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/spaces/#{tenant.id}/backups/#{job.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id
      assert data["status"] == "pending"
    end

    test "returns 404 for nonexistent job", %{conn: conn, tenant: tenant} do
      conn = get(conn, ~p"/api/v1/spaces/#{tenant.id}/backups/999")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/spaces/:space_id/backups" do
    test "creates a backup job", %{conn: conn, tenant: tenant, deployment: deployment} do
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      conn =
        post(conn, ~p"/api/v1/spaces/#{tenant.id}/backups", %{
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

  describe "POST /api/v1/spaces/:space_id/backups/:id/restore" do
    test "restores a backup job", %{conn: conn, tenant: tenant} do
      BackupTarget.configure_local()
      template = insert(:app_template, slug: "api-restore")
      deployment = insert(:deployment, tenant: tenant, app_template: template)
      dir = BackupTarget.seed_service!("api-restore", %{"a.txt" => "original"})

      {:ok, job} = Homelab.Backups.execute_backup(insert(:backup_job, deployment: deployment))
      File.write!(Path.join(dir, "a.txt"), "clobbered")

      conn = post(conn, ~p"/api/v1/spaces/#{tenant.id}/backups/#{job.id}/restore")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id

      # The restore used to be handed a literal `/data/restore`, a path no container
      # mounts, so it reported success and put the data nowhere.
      assert File.read!(Path.join(dir, "a.txt")) == "original"
    end

    test "returns 404 for nonexistent backup", %{conn: conn, tenant: tenant} do
      conn = post(conn, ~p"/api/v1/spaces/#{tenant.id}/backups/99999/restore")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/spaces/:space_id/backups with deployment_id filter" do
    test "filters backup jobs by deployment", %{
      conn: conn,
      tenant: tenant,
      deployment: deployment1
    } do
      deployment2 = insert(:deployment, tenant: tenant)
      insert(:backup_job, deployment: deployment1)
      insert(:backup_job, deployment: deployment2)

      conn =
        get(conn, ~p"/api/v1/spaces/#{tenant.id}/backups?deployment_id=#{deployment1.id}")

      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end
end
