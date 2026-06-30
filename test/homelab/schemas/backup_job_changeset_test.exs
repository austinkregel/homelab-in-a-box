defmodule Homelab.Schemas.BackupJobChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Backups.BackupJob

  defp valid_attrs(deployment) do
    %{
      deployment_id: deployment.id,
      scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }
  end

  describe "changeset/2 required fields" do
    setup do
      %{deployment: insert(:deployment)}
    end

    test "is valid with required attrs", %{deployment: deployment} do
      cs = BackupJob.changeset(%BackupJob{}, valid_attrs(deployment))
      assert cs.valid?
    end

    test "requires deployment_id and scheduled_at" do
      cs = BackupJob.changeset(%BackupJob{}, %{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.deployment_id
      assert "can't be blank" in errors.scheduled_at
    end

    test "requires deployment_id when only scheduled_at given" do
      cs = BackupJob.changeset(%BackupJob{}, %{scheduled_at: DateTime.utc_now()})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).deployment_id
    end
  end

  describe "changeset/2 status inclusion" do
    setup do
      %{deployment: insert(:deployment)}
    end

    test "accepts each valid status", %{deployment: deployment} do
      for status <- [:pending, :running, :completed, :failed] do
        attrs = valid_attrs(deployment) |> Map.put(:status, status)
        cs = BackupJob.changeset(%BackupJob{}, attrs)
        assert cs.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects an invalid status", %{deployment: deployment} do
      attrs = valid_attrs(deployment) |> Map.put(:status, :archived)
      cs = BackupJob.changeset(%BackupJob{}, attrs)
      refute cs.valid?
      # Ecto.Enum cast failure surfaces as a status error
      assert Map.has_key?(errors_on(cs), :status)
    end

    test "defaults status to pending when not provided", %{deployment: deployment} do
      {:ok, job} =
        %BackupJob{}
        |> BackupJob.changeset(valid_attrs(deployment))
        |> Repo.insert()

      assert job.status == :pending
    end
  end

  describe "foreign_key_constraint on deployment_id" do
    test "rejects a non-existent deployment_id on insert" do
      attrs = %{
        deployment_id: -1,
        scheduled_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      {:error, cs} =
        %BackupJob{}
        |> BackupJob.changeset(attrs)
        |> Repo.insert()

      assert "does not exist" in errors_on(cs).deployment_id
    end

    test "inserts successfully with a valid deployment_id" do
      deployment = insert(:deployment)

      assert {:ok, _job} =
               %BackupJob{}
               |> BackupJob.changeset(valid_attrs(deployment))
               |> Repo.insert()
    end
  end

  describe "start_changeset/1" do
    test "sets status to running and stamps started_at" do
      job = insert(:backup_job)
      cs = BackupJob.start_changeset(job)

      assert cs.valid?
      assert get_change(cs, :status) == :running
      assert %DateTime{} = get_change(cs, :started_at)
    end

    test "persists the running transition" do
      job = insert(:backup_job)
      {:ok, updated} = job |> BackupJob.start_changeset() |> Repo.update()

      assert updated.status == :running
      assert updated.started_at != nil
    end
  end

  describe "complete_changeset/3" do
    test "sets completed status, snapshot, and size" do
      job = insert(:backup_job, status: :running)
      cs = BackupJob.complete_changeset(job, "snap-abc", 4096)

      assert cs.valid?
      assert get_change(cs, :status) == :completed
      assert get_change(cs, :snapshot_id) == "snap-abc"
      assert get_change(cs, :size_bytes) == 4096
      assert %DateTime{} = get_change(cs, :completed_at)
    end

    test "persists the completion" do
      job = insert(:backup_job, status: :running)
      {:ok, updated} = job |> BackupJob.complete_changeset("snap-xyz", 100) |> Repo.update()

      assert updated.status == :completed
      assert updated.snapshot_id == "snap-xyz"
      assert updated.size_bytes == 100
      assert updated.completed_at != nil
    end
  end

  describe "fail_changeset/2" do
    test "sets failed status with error message and completed_at" do
      job = insert(:backup_job, status: :running)
      cs = BackupJob.fail_changeset(job, "disk full")

      assert cs.valid?
      assert get_change(cs, :status) == :failed
      assert get_change(cs, :error_message) == "disk full"
      assert %DateTime{} = get_change(cs, :completed_at)
    end

    test "persists the failure" do
      job = insert(:backup_job, status: :running)
      {:ok, updated} = job |> BackupJob.fail_changeset("timeout") |> Repo.update()

      assert updated.status == :failed
      assert updated.error_message == "timeout"
    end
  end
end
