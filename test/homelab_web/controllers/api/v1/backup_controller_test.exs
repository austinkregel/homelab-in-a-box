defmodule HomelabWeb.Api.V1.BackupControllerTest do
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory
  import Mox

  setup :verify_on_exit!

  setup %{conn: conn} do
    {:ok, conn: put_req_header(conn, "accept", "application/json")}
  end

  describe "GET /api/v1/backups" do
    test "lists all backup jobs", %{conn: conn} do
      deployment = insert(:deployment)
      insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/backups")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end

  describe "GET /api/v1/backups/:id" do
    test "returns backup job by id", %{conn: conn} do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment)

      conn = get(conn, ~p"/api/v1/backups/#{job.id}")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id
      assert data["status"] == "pending"
    end

    test "returns 404 for nonexistent job", %{conn: conn} do
      conn = get(conn, ~p"/api/v1/backups/999")
      assert json_response(conn, 404)
    end
  end

  describe "POST /api/v1/backups" do
    test "creates a backup job", %{conn: conn} do
      deployment = insert(:deployment)
      now = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      conn =
        post(conn, ~p"/api/v1/backups", %{
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

  describe "POST /api/v1/backups/:id/restore" do
    test "restores a backup job", %{conn: conn} do
      deployment = insert(:deployment)

      job =
        insert(:backup_job,
          deployment: deployment,
          status: :completed,
          snapshot_id: "snap-abc123"
        )

      Homelab.Mocks.BackupProvider
      |> expect(:restore, fn "snap-abc123", "/data/restore" -> :ok end)

      conn = post(conn, ~p"/api/v1/backups/#{job.id}/restore")
      assert %{"data" => data} = json_response(conn, 200)
      assert data["id"] == job.id
    end

    test "returns 404 for nonexistent backup", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/backups/99999/restore")
      assert json_response(conn, 404)
    end
  end

  describe "GET /api/v1/backups with deployment_id filter" do
    test "filters backup jobs by deployment", %{conn: conn} do
      deployment1 = insert(:deployment)
      deployment2 = insert(:deployment)
      insert(:backup_job, deployment: deployment1)
      insert(:backup_job, deployment: deployment2)

      conn = get(conn, ~p"/api/v1/backups?deployment_id=#{deployment1.id}")
      assert %{"data" => jobs} = json_response(conn, 200)
      assert length(jobs) == 1
    end
  end
end
