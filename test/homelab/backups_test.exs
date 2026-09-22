defmodule Homelab.BackupsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Backups
  alias Homelab.Backups.BackupJob
  import Homelab.Factory
  import Mox

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
    setup :verify_on_exit!

    test "records the snapshot on success" do
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:ok, "snap_abc123"}
      end)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :completed
      assert updated.snapshot_id == "snap_abc123"
    end

    test "fails the job when the provider returns an error" do
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:error, {:restic_missing, "restic is not installed or not on PATH"}}
      end)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :failed
      assert updated.error_message =~ "restic is not installed"
    end

    test "records a failure an operator can read, keeping the original term" do
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:error, {:restic_missing, "restic is not installed or not on PATH"}}
      end)

      assert {:ok, updated} = Backups.execute_backup(job)

      parsed = Homelab.Backups.Failure.from_message(updated.error_message)
      assert parsed.summary =~ "not installed"
      refute parsed.summary =~ ":restic_missing"
      assert parsed.detail =~ ":restic_missing"
    end

    # A scheduled backup failing has nobody watching a flash, and used to write nothing
    # to the activity log and raise no notification.
    test "announces a failure to the activity log and to admins" do
      admin = insert(:user, role: :admin)
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:error, {:restic_missing, "restic is not installed"}}
      end)

      assert {:ok, _} = Backups.execute_backup(job)

      assert Enum.any?(Homelab.Services.ActivityLog.all(), fn event ->
               event.source == "backups" and event.level == :error and
                 event.message =~ "failed"
             end)

      assert [notification] = Homelab.Notifications.list_unread(admin.id)
      assert notification.title =~ "Backup failed"
      assert notification.body =~ "not installed"
      assert notification.severity == "error"

      # The notification has to land somewhere that shows the reason, which is the
      # deployment's own backups tab.
      assert notification.link == "/deployments/#{job.deployment_id}?tab=backups"
    end

    # The row is written before anything is announced, so a notification never refers
    # to a run whose outcome has not settled.
    test "records the outcome before announcing it" do
      admin = insert(:user, role: :admin)
      job = insert(:backup_job, deployment: insert(:deployment))
      Phoenix.PubSub.subscribe(Homelab.PubSub, "notifications:#{admin.id}")

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:error, {:restic_missing, "restic is not installed"}}
      end)

      assert {:ok, _} = Backups.execute_backup(job)

      assert_receive {:notification, _}, 1_000
      assert Backups.get_backup_job(job.id) |> elem(1) |> Map.get(:status) == :failed
    end

    test "announces a success to the activity log" do
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        {:ok, "snap_ok"}
      end)

      assert {:ok, _} = Backups.execute_backup(job)

      assert Enum.any?(Homelab.Services.ActivityLog.all(), fn event ->
               event.source == "backups" and event.level == :info and
                 event.message =~ "completed"
             end)
    end

    # A provider that shells out to a missing binary raises rather than returning an
    # error tuple. Before, that left the row on `:running` with no error_message, so the
    # Backups page showed a backup in progress forever.
    test "fails the job when the provider raises" do
      job = insert(:backup_job, deployment: insert(:deployment))

      expect(Homelab.Mocks.BackupProvider, :backup, fn _source, _repo, _tags ->
        raise ErlangError, original: :enoent
      end)

      assert {:ok, updated} = Backups.execute_backup(job)
      assert updated.status == :failed
      assert updated.error_message =~ "enoent"
      assert updated.completed_at != nil
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
