defmodule Homelab.Services.RegistrarSyncerTest do
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Homelab.Services.RegistrarSyncer

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    :ok
  end

  describe "start_link/1 and status/0" do
    test "starts and returns initial status" do
      pid = start_supervised!({RegistrarSyncer, enabled: false})
      assert is_pid(pid)

      status = RegistrarSyncer.status()
      assert status.last_sync_at == nil
      assert status.last_result == nil
    end
  end

  describe "sync_now/0" do
    test "triggers immediate sync" do
      Homelab.Mocks.RegistrarProvider
      |> stub(:list_domains, fn -> {:ok, []} end)

      start_supervised!({RegistrarSyncer, enabled: false})
      RegistrarSyncer.sync_now()

      Process.sleep(100)

      status = RegistrarSyncer.status()
      assert status.last_sync_at != nil
    end
  end

  describe "handle_info :sync" do
    test "does not crash the GenServer" do
      Homelab.Mocks.RegistrarProvider
      |> stub(:list_domains, fn -> {:ok, []} end)

      pid = start_supervised!({RegistrarSyncer, enabled: false})
      send(pid, :sync)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "sync_now when registrar returns error" do
    test "handles error from registrar gracefully" do
      Homelab.Mocks.RegistrarProvider
      |> stub(:list_domains, fn -> {:error, :connection_refused} end)

      start_supervised!({RegistrarSyncer, enabled: false})

      log =
        capture_log(fn ->
          RegistrarSyncer.sync_now()
          Process.sleep(100)
        end)

      assert log =~ "[RegistrarSyncer] Sync failed: :connection_refused"

      status = RegistrarSyncer.status()
      assert status.last_sync_at != nil
    end
  end

  describe "status/0 shape" do
    test "returns map with expected keys" do
      start_supervised!({RegistrarSyncer, enabled: false})
      status = RegistrarSyncer.status()

      assert is_map(status)
      assert Map.has_key?(status, :last_sync_at)
      assert Map.has_key?(status, :last_result)
    end
  end
end
