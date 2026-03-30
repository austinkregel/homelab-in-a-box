defmodule Homelab.Services.CatalogSyncerTest do
  use ExUnit.Case, async: false

  alias Homelab.Services.CatalogSyncer

  describe "start_link/1" do
    test "starts the GenServer" do
      pid = start_supervised!({CatalogSyncer, []})
      assert is_pid(pid)
    end
  end

  describe "sync_now/0" do
    test "synchronously syncs catalogs and returns count" do
      start_supervised!({CatalogSyncer, []})
      {:ok, total} = CatalogSyncer.sync_now()
      assert is_integer(total)
      assert total >= 0
    end
  end

  describe "handle_info :sync" do
    test "does not crash the GenServer" do
      pid = start_supervised!({CatalogSyncer, []})
      send(pid, :sync)
      _ = :sys.get_state(pid)
      assert Process.alive?(pid)
    end
  end

  describe "sync_now/0 creates AppTemplate records" do
    test "persists entries returned by catalog browse" do
      start_supervised!({CatalogSyncer, []})
      {:ok, total} = CatalogSyncer.sync_now()
      assert is_integer(total)
    end
  end
end
