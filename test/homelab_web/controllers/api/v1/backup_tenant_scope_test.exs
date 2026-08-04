defmodule HomelabWeb.Api.V1.BackupTenantScopeTest do
  @moduledoc """
  `BackupController` was routed at the top level — `/api/v1/backups` — while every other
  resource hung off `/api/v1/tenants/:tenant_id/...`. `index` fell through to
  `Backups.list_backup_jobs/0`, which is every tenant's jobs, and `show` and `restore`
  took a bare id and looked it up with no scope at all. Any signed-in user could list
  every tenant's backup history and, worse, `POST /api/v1/backups/:id/restore` any
  tenant's snapshot over `/data/restore`.

  These tests drive the tenant-scoped paths, which is the fix: a backup that belongs to
  another tenant must be a 404 through this API, not a 200.

  A caveat worth stating plainly, because these tests can read as more than they are:
  there is no `tenant_id` on `users` and no join table, so tenants are not an access
  boundary yet — a user can still address any tenant by walking the path. What this
  closes is the ambient, unscoped surface: after it, an id is only meaningful inside the
  tenant it belongs to, and there is exactly one place to enforce membership when a
  membership model finally exists. It is a prerequisite for that model, not a substitute.
  """
  use HomelabWeb.ConnCase, async: true

  import Homelab.Factory
  import Mox

  setup :verify_on_exit!

  setup %{conn: conn} do
    mine = insert(:tenant)
    theirs = insert(:tenant)

    my_job = insert(:backup_job, deployment: insert(:deployment, tenant: mine))

    their_job =
      insert(:backup_job,
        deployment: insert(:deployment, tenant: theirs),
        status: :completed,
        snapshot_id: "their-snapshot"
      )

    {:ok,
     conn: put_req_header(conn, "accept", "application/json"),
     mine: mine,
     theirs: theirs,
     my_job: my_job,
     their_job: their_job}
  end

  describe "index" do
    test "lists only the addressed tenant's jobs", %{conn: conn, mine: mine, my_job: my_job} do
      conn = get(conn, ~p"/api/v1/tenants/#{mine.id}/backups")

      assert %{"data" => [job]} = json_response(conn, 200)
      assert job["id"] == my_job.id
    end

    test "a deployment_id filter cannot reach out of the tenant", %{
      conn: conn,
      mine: mine,
      their_job: their_job
    } do
      conn =
        get(conn, ~p"/api/v1/tenants/#{mine.id}/backups?deployment_id=#{their_job.deployment_id}")

      assert json_response(conn, 404)
    end
  end

  describe "show" do
    test "returns the tenant's own job", %{conn: conn, mine: mine, my_job: my_job} do
      conn = get(conn, ~p"/api/v1/tenants/#{mine.id}/backups/#{my_job.id}")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == my_job.id
    end

    test "404s for another tenant's job", %{conn: conn, mine: mine, their_job: their_job} do
      conn = get(conn, ~p"/api/v1/tenants/#{mine.id}/backups/#{their_job.id}")

      assert json_response(conn, 404)
    end
  end

  describe "restore" do
    test "restores the tenant's own snapshot", %{conn: conn, mine: mine} do
      job =
        insert(:backup_job,
          deployment: insert(:deployment, tenant: mine),
          status: :completed,
          snapshot_id: "my-snapshot"
        )

      expect(Homelab.Mocks.BackupProvider, :restore, fn "my-snapshot", "/data/restore" -> :ok end)

      conn = post(conn, ~p"/api/v1/tenants/#{mine.id}/backups/#{job.id}/restore")

      assert %{"data" => %{"id" => id}} = json_response(conn, 200)
      assert id == job.id
    end

    test "will not restore another tenant's snapshot", %{
      conn: conn,
      mine: mine,
      their_job: their_job
    } do
      # The whole point: no `expect` on the provider, so a call to it fails the test.
      # A 404 that still ran the restore would be worthless.
      conn = post(conn, ~p"/api/v1/tenants/#{mine.id}/backups/#{their_job.id}/restore")

      assert json_response(conn, 404)
    end
  end

  describe "create" do
    test "schedules a backup for the tenant's own deployment", %{conn: conn, mine: mine} do
      deployment = insert(:deployment, tenant: mine)
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()

      conn =
        post(conn, ~p"/api/v1/tenants/#{mine.id}/backups", %{
          "backup" => %{"deployment_id" => deployment.id, "scheduled_at" => at}
        })

      assert %{"data" => data} = json_response(conn, 201)
      assert data["deployment_id"] == deployment.id
      assert data["status"] == "pending"
    end

    test "refuses to schedule against another tenant's deployment", %{
      conn: conn,
      mine: mine,
      their_job: their_job
    } do
      at = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
      before = Homelab.Repo.aggregate(Homelab.Backups.BackupJob, :count)

      conn =
        post(conn, ~p"/api/v1/tenants/#{mine.id}/backups", %{
          "backup" => %{"deployment_id" => their_job.deployment_id, "scheduled_at" => at}
        })

      assert json_response(conn, 404)
      assert Homelab.Repo.aggregate(Homelab.Backups.BackupJob, :count) == before
    end
  end

  describe "the unscoped routes" do
    test "are gone", %{my_job: my_job} do
      # Left in place they would be a bypass of everything above. Plain strings, not
      # ~p: these paths must not resolve, and a sigil would fail to compile once
      # they don't.
      assert_raise Phoenix.Router.NoRouteError, fn ->
        get(build_conn(), "/api/v1/backups")
      end

      assert_raise Phoenix.Router.NoRouteError, fn ->
        post(build_conn(), "/api/v1/backups/#{my_job.id}/restore")
      end
    end
  end
end
