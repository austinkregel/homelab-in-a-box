defmodule Homelab.Services.BackupSchedulerTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Services.BackupScheduler

  setup :set_mox_global
  setup :verify_on_exit!

  describe "init/1" do
    test "starts with default state" do
      start_supervised!({BackupScheduler, enabled: false})
      status = BackupScheduler.status()

      assert status.last_check_at == nil
      assert status.jobs_dispatched == 0
    end
  end

  describe "backup scheduling" do
    test "dispatches due backup jobs" do
      deployment = insert(:deployment)
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      insert(:backup_job, deployment: deployment, scheduled_at: past, status: :pending)

      Homelab.Mocks.BackupProvider
      |> expect(:backup, fn _source, _repo, _tags -> {:ok, "snap_123"} end)

      start_supervised!({BackupScheduler, enabled: false, interval: :timer.hours(1)})
      BackupScheduler.check_now()
      Process.sleep(300)

      status = BackupScheduler.status()
      assert status.jobs_dispatched == 1
    end

    test "does not dispatch future backup jobs" do
      deployment = insert(:deployment)
      future = DateTime.utc_now() |> DateTime.add(1, :hour) |> DateTime.truncate(:second)
      insert(:backup_job, deployment: deployment, scheduled_at: future, status: :pending)

      start_supervised!({BackupScheduler, enabled: false, interval: :timer.hours(1)})
      BackupScheduler.check_now()
      Process.sleep(200)

      status = BackupScheduler.status()
      assert status.jobs_dispatched == 0
    end
  end
end
