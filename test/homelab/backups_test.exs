defmodule Homelab.BackupsTest do
  # Not async: the local target is configured through Settings, whose cache is global.
  use Homelab.DataCase, async: false

  alias Homelab.Backups
  alias Homelab.Backups.BackupJob
  alias Homelab.Backups.Failure
  alias Homelab.BackupTarget
  import Homelab.Factory

  describe "list_backup_jobs/0" do
    test "returns all backup jobs ordered by scheduled_at desc" do
      deployment = insert(:deployment)
      early = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      late = DateTime.utc_now() |> DateTime.truncate(:second)

      insert(:backup_job, deployment: deployment, scheduled_at: early)
      insert(:backup_job, deployment: deployment, scheduled_at: late)

      jobs = Backups.list_backup_jobs()
      assert length(jobs) == 2
      assert hd(jobs).scheduled_at == late
    end
  end

  describe "list_backup_jobs_for_deployment/1" do
    test "returns jobs for a specific deployment" do
      deployment = insert(:deployment)
      other_deployment = insert(:deployment)
      insert(:backup_job, deployment: deployment)
      insert(:backup_job, deployment: other_deployment)

      jobs = Backups.list_backup_jobs_for_deployment(deployment.id)
      assert length(jobs) == 1
      assert hd(jobs).deployment_id == deployment.id
    end
  end

  describe "list_due_backups/1" do
    test "returns pending backups scheduled before now" do
      deployment = insert(:deployment)
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      future = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      insert(:backup_job, deployment: deployment, scheduled_at: past, status: :pending)
      insert(:backup_job, deployment: deployment, scheduled_at: future, status: :pending)
      insert(:backup_job, deployment: deployment, scheduled_at: past, status: :completed)

      due = Backups.list_due_backups(now)
      assert length(due) == 1
      assert hd(due).status == :pending
    end
  end

  describe "get_backup_job/1" do
    test "returns backup job by id" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment)
      assert {:ok, found} = Backups.get_backup_job(job.id)
      assert found.id == job.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Backups.get_backup_job(999)
    end
  end

  describe "create_backup_job/1" do
    test "creates a backup job with valid attrs" do
      deployment = insert(:deployment)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      attrs = %{
        deployment_id: deployment.id,
        scheduled_at: now
      }

      assert {:ok, %BackupJob{} = job} = Backups.create_backup_job(attrs)
      assert job.status == :pending
      assert job.deployment_id == deployment.id
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Backups.create_backup_job(%{})
      assert errors_on(changeset).deployment_id != []
      assert errors_on(changeset).scheduled_at != []
    end
  end

  describe "start_backup/1" do
    test "transitions job to running with started_at" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, updated} = Backups.start_backup(job)
      assert updated.status == :running
      assert updated.started_at != nil
    end
  end

  describe "complete_backup/3" do
    test "transitions job to completed with snapshot info" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment, status: :running)

      assert {:ok, updated} = Backups.complete_backup(job, "snap_abc123", 1024)
      assert updated.status == :completed
      assert updated.snapshot_id == "snap_abc123"
      assert updated.size_bytes == 1024
      assert updated.completed_at != nil
    end
  end

  describe "fail_backup/2" do
    test "transitions job to failed with error message" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment, status: :running)

      assert {:ok, updated} = Backups.fail_backup(job, "Disk full")
      assert updated.status == :failed
      assert updated.error_message == "Disk full"
      assert updated.completed_at != nil
    end
  end

  describe "execute_backup/1" do
    setup do
      paths = BackupTarget.configure_local()
      template = insert(:app_template, slug: "plex")
      deployment = insert(:deployment, app_template: template)
      BackupTarget.seed_service!("plex", %{"config/prefs.xml" => "<prefs/>"})

      Map.merge(paths, %{deployment: deployment})
    end

    test "archives the volume and records what it takes to restore it", %{
      deployment: deployment
    } do
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :completed
      assert updated.target_kind == "local_disk"
      assert updated.archive_key =~ "plex/"

      # Size is the volume's real size now, so an empty backup is distinguishable from
      # a small one rather than both rendering as a dash.
      assert updated.size_bytes > 0

      manifest = updated.manifest
      assert Regex.match?(~r/^[0-9a-f]{64}$/, manifest["plaintext_sha256"])
      assert manifest["wrapped_data_key"] != nil
      assert manifest["frames"] >= 1
      assert updated.snapshot_id == manifest["id"]
    end

    test "the archive round-trips back to the original bytes", %{deployment: deployment} do
      job = insert(:backup_job, deployment: deployment)
      {:ok, completed} = Backups.execute_backup(job)

      dir = Homelab.Deployments.PermanentHome.service_dir("plex")
      File.write!(Path.join(dir, "config/prefs.xml"), "clobbered")

      assert :ok = Backups.restore_backup(completed.id)
      assert File.read!(Path.join(dir, "config/prefs.xml")) == "<prefs/>"
    end

    test "deep verification reads the archive back without writing anything", %{
      deployment: deployment
    } do
      job = insert(:backup_job, deployment: deployment)
      {:ok, completed} = Backups.execute_backup(job)

      assert :ok = Backups.verify_backup(completed)
    end

    test "a corrupt archive fails verification rather than reporting protection", %{
      deployment: deployment,
      backup_root: root
    } do
      job = insert(:backup_job, deployment: deployment)
      {:ok, completed} = Backups.execute_backup(job)

      frame = Path.join([root, completed.archive_key, "frames", "00000000"])
      <<head::binary-40, byte, rest::binary>> = File.read!(frame)
      File.write!(frame, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

      assert {:error, _} = Backups.verify_backup(completed)
    end

    test "fails the job when no destination is configured", %{deployment: deployment} do
      BackupTarget.unconfigure()
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :failed
      assert Failure.from_message(updated.error_message).detail =~ "no_target_configured"
    end

    test "fails the job when the volume does not exist", %{deployment: deployment} do
      File.rm_rf!(Homelab.Deployments.PermanentHome.service_dir("plex"))
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :failed
      assert Failure.from_message(updated.error_message).summary =~ "nothing at"
    end

    # A scheduled backup failing has nobody watching a flash, and used to write nothing
    # to the activity log and raise no notification.
    test "announces a failure to the activity log and to admins", %{deployment: deployment} do
      admin = insert(:user, role: :admin)
      BackupTarget.unconfigure()
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, _} = Backups.execute_backup(job)

      assert Enum.any?(Homelab.Services.ActivityLog.all(), fn event ->
               event.source == "backups" and event.level == :error and
                 event.message =~ "failed"
             end)

      assert [notification] = Homelab.Notifications.list_unread(admin.id)
      assert notification.title =~ "Backup failed"
      assert notification.severity == "error"
      assert notification.link == "/deployments/#{job.deployment_id}?tab=backups"
    end

    # The row is written before anything is announced, so a notification never refers
    # to a run whose outcome has not settled.
    test "records the outcome before announcing it", %{deployment: deployment} do
      admin = insert(:user, role: :admin)
      BackupTarget.unconfigure()
      job = insert(:backup_job, deployment: deployment)
      Phoenix.PubSub.subscribe(Homelab.PubSub, "notifications:#{admin.id}")

      assert {:ok, _} = Backups.execute_backup(job)

      assert_receive {:notification, _}, 1_000
      assert Backups.get_backup_job(job.id) |> elem(1) |> Map.get(:status) == :failed
    end

    test "announces a success to the activity log", %{deployment: deployment} do
      job = insert(:backup_job, deployment: deployment)

      assert {:ok, _} = Backups.execute_backup(job)

      assert Enum.any?(Homelab.Services.ActivityLog.all(), fn event ->
               event.source == "backups" and event.level == :info and
                 event.message =~ "completed"
             end)
    end

    # An unconfigured managed root raises rather than guessing a path. A raise that
    # escaped left `status: :running` with a blank error forever.
    test "a raise becomes a failed job rather than a wedged one", %{deployment: deployment} do
      Application.delete_env(:homelab, :managed_root)
      Application.put_env(:homelab, :containerized, true)
      on_exit(fn -> Application.delete_env(:homelab, :containerized) end)

      job = insert(:backup_job, deployment: deployment)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :failed
      assert updated.completed_at != nil
    end
  end

  describe "restore_backup/1" do
    test "refuses a row that has no archive behind it" do
      job = insert(:backup_job, deployment: insert(:deployment), status: :completed)

      assert {:error, :no_archive_manifest} = Backups.restore_backup(job.id)
    end

    test "rejects an id that is not a number" do
      assert {:error, {:invalid_backup_id, "abc"}} = Backups.restore_backup("abc")
    end
  end

  describe "delete_backup_job/1" do
    test "deletes a backup job" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment)
      assert {:ok, _} = Backups.delete_backup_job(job)
      assert {:error, :not_found} = Backups.get_backup_job(job.id)
    end
  end
end
