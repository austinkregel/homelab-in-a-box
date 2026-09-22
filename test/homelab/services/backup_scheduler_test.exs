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
    # The case this whole surface exists for: a scheduled run fails with nobody
    # watching a flash. The work happens in a Task under the worker supervisor, so the
    # notification has to escape a process the scheduler does not wait on.
    test "a failing scheduled backup reaches an admin" do
      admin = insert(:user, role: :admin)
      deployment = insert(:deployment)
      past = DateTime.utc_now() |> DateTime.add(-1, :hour) |> DateTime.truncate(:second)
      insert(:backup_job, deployment: deployment, scheduled_at: past, status: :pending)

      Phoenix.PubSub.subscribe(Homelab.PubSub, "notifications:#{admin.id}")

      Homelab.Mocks.BackupProvider
      |> expect(:backup, fn _source, _repo, _tags ->
        {:error, {:restic_missing, "restic is not installed"}}
      end)

      start_supervised!({BackupScheduler, enabled: false, interval: :timer.hours(1)})
      BackupScheduler.check_now()

      assert_receive {:notification, notification}, 5_000
      assert notification.title =~ "Backup failed"
      assert notification.body =~ "not installed"
      assert notification.link == "/deployments/#{deployment.id}?tab=backups"
    end

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

  describe "handle_info :check_schedules" do
    test "does not crash the GenServer" do
      pid = start_supervised!({BackupScheduler, enabled: false})
      send(pid, :check_schedules)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "status/0 shape" do
    test "returns map with expected keys" do
      start_supervised!({BackupScheduler, enabled: false})
      status = BackupScheduler.status()

      assert is_map(status)
      assert Map.has_key?(status, :last_check_at)
      assert Map.has_key?(status, :jobs_dispatched)
      assert Map.has_key?(status, :interval)
      assert Map.has_key?(status, :enabled)
      assert status.enabled == false
    end
  end
end
