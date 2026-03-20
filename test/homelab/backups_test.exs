defmodule Homelab.BackupsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Backups
  alias Homelab.Backups.BackupJob
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

  describe "delete_backup_job/1" do
    test "deletes a backup job" do
      deployment = insert(:deployment)
      job = insert(:backup_job, deployment: deployment)
      assert {:ok, _} = Backups.delete_backup_job(job)
      assert {:error, :not_found} = Backups.get_backup_job(job.id)
    end
  end
end
