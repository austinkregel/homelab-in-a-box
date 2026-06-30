defmodule HomelabWeb.Api.V1.BackupJSONTest do
  use ExUnit.Case, async: true

  alias HomelabWeb.Api.V1.BackupJSON
  alias Homelab.Backups.BackupJob

  defp backup_job(attrs \\ %{}) do
    defaults = %BackupJob{
      id: 1,
      status: :completed,
      deployment_id: 42,
      scheduled_at: ~U[2026-06-26 02:00:00Z],
      started_at: ~U[2026-06-26 02:00:05Z],
      completed_at: ~U[2026-06-26 02:05:00Z],
      snapshot_id: "snap-abc",
      size_bytes: 1_048_576,
      error_message: nil,
      inserted_at: ~N[2026-06-01 00:00:00],
      updated_at: ~N[2026-06-02 00:00:00]
    }

    struct(defaults, attrs)
  end

  describe "show/1" do
    test "wraps a single backup job under :data" do
      assert %{data: data} = BackupJSON.show(%{backup_job: backup_job()})
      assert is_map(data)
    end

    test "renders all expected fields" do
      j = backup_job()
      %{data: data} = BackupJSON.show(%{backup_job: j})

      assert data.id == j.id
      assert data.status == j.status
      assert data.deployment_id == j.deployment_id
      assert data.scheduled_at == j.scheduled_at
      assert data.started_at == j.started_at
      assert data.completed_at == j.completed_at
      assert data.snapshot_id == j.snapshot_id
      assert data.size_bytes == j.size_bytes
      assert data.error_message == j.error_message
      assert data.inserted_at == j.inserted_at
      assert data.updated_at == j.updated_at
    end

    test "exposes exactly the documented key set" do
      %{data: data} = BackupJSON.show(%{backup_job: backup_job()})

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :status,
                 :deployment_id,
                 :scheduled_at,
                 :started_at,
                 :completed_at,
                 :snapshot_id,
                 :size_bytes,
                 :error_message,
                 :inserted_at,
                 :updated_at
               ])
    end

    test "preserves nil optional fields for a pending (not-yet-run) job" do
      j =
        backup_job(%{
          status: :pending,
          started_at: nil,
          completed_at: nil,
          snapshot_id: nil,
          size_bytes: nil,
          error_message: nil
        })

      %{data: data} = BackupJSON.show(%{backup_job: j})

      assert data.status == :pending
      assert data.started_at == nil
      assert data.completed_at == nil
      assert data.snapshot_id == nil
      assert data.size_bytes == nil
      assert data.error_message == nil
    end

    test "includes error_message for a failed job" do
      j = backup_job(%{status: :failed, error_message: "restic timeout", snapshot_id: nil})
      %{data: data} = BackupJSON.show(%{backup_job: j})

      assert data.status == :failed
      assert data.error_message == "restic timeout"
    end

    test "renders zero size_bytes (not treated as nil)" do
      %{data: data} = BackupJSON.show(%{backup_job: backup_job(%{size_bytes: 0})})
      assert data.size_bytes == 0
    end
  end

  describe "index/1" do
    test "wraps a list of backup jobs under :data" do
      js = [backup_job(%{id: 1}), backup_job(%{id: 2})]
      %{data: list} = BackupJSON.index(%{backup_jobs: js})

      assert length(list) == 2
      assert Enum.map(list, & &1.id) == [1, 2]
    end

    test "returns empty list for no backup jobs" do
      assert BackupJSON.index(%{backup_jobs: []}) == %{data: []}
    end

    test "shapes each element identically to show/1" do
      j = backup_job(%{id: 5})
      %{data: [from_index]} = BackupJSON.index(%{backup_jobs: [j]})
      %{data: from_show} = BackupJSON.show(%{backup_job: j})

      assert from_index == from_show
    end
  end
end
