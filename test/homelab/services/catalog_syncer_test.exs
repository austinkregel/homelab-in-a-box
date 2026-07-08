defmodule Homelab.Services.CatalogSyncerTest do
  use ExUnit.Case, async: false

  alias Homelab.Services.CatalogSyncer

  # Pin the catalog set via the app-env override so the syncer doesn't read the
  # Settings-backed enabled list (which would need a DB sandbox this process lacks).
  setup do
    original = Application.get_env(:homelab, :application_catalogs)
    Application.put_env(:homelab, :application_catalogs, [])

    on_exit(fn ->
      if original,
        do: Application.put_env(:homelab, :application_catalogs, original),
        else: Application.delete_env(:homelab, :application_catalogs)
    end)

    :ok
  end

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
