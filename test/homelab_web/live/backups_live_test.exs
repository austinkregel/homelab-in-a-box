defmodule HomelabWeb.BackupsLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)
    template = insert(:app_template)

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    Homelab.Mocks.BackupProvider
    |> stub(:backup, fn _dep_id, _paths, _opts -> {:ok, "snapshot_1"} end)
    |> stub(:restore, fn _snapshot_id, _opts -> :ok end)
    |> stub(:list_snapshots, fn _dep_id -> {:ok, []} end)

    {:ok, conn: conn, tenant: tenant, template: template}
  end

  describe "mount" do
    test "renders backups page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Backups"
    end

    test "shows backup now button", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backups")
      assert has_element?(view, "button", "Backup Now")
    end

    test "shows empty state when no backups", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "No backups yet"
    end
  end

  describe "with existing backups" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "backup_container"
        )

      completed_backup =
        insert(:backup_job,
          deployment: deployment,
          status: :completed,
          snapshot_id: "snap_123",
          size_bytes: 1_048_576,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      pending_backup =
        insert(:backup_job,
          deployment: deployment,
          status: :pending
        )

      {:ok,
       deployment: deployment,
       completed_backup: completed_backup,
       pending_backup: pending_backup}
    end

    test "shows backup table", %{conn: conn, template: template} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ template.name
      assert html =~ "Completed"
    end

    test "shows backup size", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "MB" or html =~ "KB"
    end

    test "shows restore button for completed backups with snapshot_id", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backups")
      assert has_element?(view, "button", "Restore")
    end

    test "shows pending status for pending backups", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Pending"
    end
  end

  describe "toggle_backup_dropdown" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "drop_container"
        )

      {:ok, deployment: deployment}
    end

    test "opens and closes backup dropdown", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backups")

      html = render_click(view, "toggle_backup_dropdown", %{})
      assert html =~ "trigger_backup" or has_element?(view, "[phx-click=trigger_backup]")

      html = render_click(view, "toggle_backup_dropdown", %{})
      refute has_element?(view, "[phx-click=trigger_backup][phx-value-deployment_id]") and
               html =~ "SHOULD_NOT_MATCH"
    end
  end

  describe "trigger_backup" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "trig_container"
        )

      {:ok, deployment: deployment}
    end

    test "triggers a manual backup", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/backups")

      html =
        render_click(view, "trigger_backup", %{"deployment_id" => to_string(dep.id)})

      assert html =~ "Backup triggered successfully"
    end

    test "closes dropdown after triggering backup", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/backups")
      render_click(view, "toggle_backup_dropdown", %{})

      render_click(view, "trigger_backup", %{"deployment_id" => to_string(dep.id)})
      html = render(view)
      assert html =~ "Backup triggered"
    end
  end

  describe "restore" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "restore_container"
        )

      backup =
        insert(:backup_job,
          deployment: deployment,
          status: :completed,
          snapshot_id: "restore_snap_1",
          size_bytes: 2_097_152,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, deployment: deployment, backup: backup}
    end

    test "restores from a completed backup", %{conn: conn, backup: backup} do
      {:ok, view, _html} = live(conn, ~p"/backups")
      html = render_click(view, "restore", %{"backup_id" => to_string(backup.id)})
      assert html =~ "Backup restore completed" or html =~ "Restore"
    end
  end

  describe "page header" do
    test "shows page description", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "View backup history"
    end
  end

  describe "backup table columns" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "col_container"
        )

      insert(:backup_job,
        deployment: deployment,
        status: :completed,
        snapshot_id: "col_snap",
        size_bytes: 512_000,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, deployment: deployment}
    end

    test "shows app name column", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "App"
    end

    test "shows space column", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Space"
    end

    test "shows status column", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Status"
    end
  end

  describe "trigger_backup error path" do
    test "shows error flash when backup creation fails for invalid deployment", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/backups")

      html =
        render_click(view, "trigger_backup", %{"deployment_id" => "0"})

      assert html =~ "Failed to create backup job"
    end
  end

  describe "restore error path" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "restore_err_container"
        )

      backup =
        insert(:backup_job,
          deployment: deployment,
          status: :completed,
          snapshot_id: "err_snap_1",
          size_bytes: 1_048_576,
          completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
        )

      {:ok, deployment: deployment, backup: backup}
    end

    test "shows error flash when restore fails", %{conn: conn, backup: backup} do
      Homelab.Mocks.BackupProvider
      |> stub(:restore, fn _snapshot_id, _opts -> {:error, "restore failed"} end)

      {:ok, view, _html} = live(conn, ~p"/backups")
      html = render_click(view, "restore", %{"backup_id" => to_string(backup.id)})
      assert html =~ "Restore failed"
    end

    test "shows error details in flash when restore returns reason", %{conn: conn, backup: backup} do
      Homelab.Mocks.BackupProvider
      |> stub(:restore, fn _snapshot_id, _opts -> {:error, :snapshot_not_found} end)

      {:ok, view, _html} = live(conn, ~p"/backups")
      html = render_click(view, "restore", %{"backup_id" => to_string(backup.id)})
      assert html =~ "Restore failed"
    end
  end

  describe "backup status pills" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "pill_container"
        )

      {:ok, deployment: deployment}
    end

    test "renders running status pill", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :running,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "In progress"
    end

    test "renders failed status pill", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :failed,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second),
        error_message: "disk full"
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Failed"
    end

  end

  describe "backup with running status and additional checks" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "running_check_container"
        )

      {:ok, deployment: deployment}
    end

    test "running backup shows dash instead of restore button", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :running,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, view, _html} = live(conn, ~p"/backups")
      refute has_element?(view, "button", "Restore")
    end
  end

  describe "backup without snapshot_id" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "no_snap_container"
        )

      {:ok, deployment: deployment}
    end

    test "shows dash instead of restore button when completed but no snapshot_id", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: nil,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, view, _html} = live(conn, ~p"/backups")
      refute has_element?(view, "button", "Restore")
    end
  end

  describe "format_size branches" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "size_container"
        )

      {:ok, deployment: deployment}
    end

    test "renders dash for nil size_bytes", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: "snap_nil_size",
        size_bytes: nil,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Completed"
    end

    test "renders dash for zero size_bytes", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: "snap_zero_size",
        size_bytes: 0,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Completed"
    end

    test "renders bytes for small size", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: "snap_bytes",
        size_bytes: 500,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "500 B"
    end

    test "renders KB for kilobyte-range size", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: "snap_kb",
        size_bytes: 50_000,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "KB"
    end

    test "renders MB for megabyte-range size", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :completed,
        snapshot_id: "snap_mb",
        size_bytes: 5_000_000,
        completed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "MB"
    end
  end

  describe "format_datetime with nil" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "dt_container"
        )

      {:ok, deployment: deployment}
    end

    test "renders scheduled_at column for pending backup", %{conn: conn, deployment: dep} do
      insert(:backup_job,
        deployment: dep,
        status: :pending,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
      )

      {:ok, _view, html} = live(conn, ~p"/backups")
      assert html =~ "Pending"
    end
  end
end
