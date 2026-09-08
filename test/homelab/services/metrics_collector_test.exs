defmodule Homelab.Services.MetricsCollectorTest do
  # DataCase, not ExUnit.Case: the collector persists from its own process, so it
  # needs the sandbox in shared mode to reach the test's transaction. Without an
  # owner the poll's insert_all raises and persist_snapshot/1 swallows it.
  use Homelab.DataCase, async: false

  alias Homelab.Services.MetricsCollector
  alias Homelab.Telemetry.Sample

  describe "start_link/1" do
    test "starts the GenServer" do
      pid = start_supervised!({MetricsCollector, []})
      assert is_pid(pid)
    end
  end

  describe "get_latest/0" do
    test "returns nil before first poll" do
      start_supervised!({MetricsCollector, []})
      assert MetricsCollector.get_latest() == nil
    end

    test "a poll cycle persists a snapshot, broadcasts it, and keeps the state" do
      Phoenix.PubSub.subscribe(Homelab.PubSub, "metrics:update")
      pid = start_supervised!({MetricsCollector, []})

      send(pid, :poll)

      # persist_snapshot/1 runs before the broadcast, so receiving this means the
      # samples are already committed. The poll shells out for host metrics and
      # scrapes Traefik, hence the generous window.
      assert_receive {:metrics, metrics}, 15_000

      # cpu_percent always yields a numeric value (0.0 when /proc/stat is
      # unreadable), so this row is written on every poll.
      assert Repo.exists?(
               from s in Sample, where: s.source == "host" and s.metric == "cpu_percent"
             )

      # Answering the call proves the collector is still alive after persisting.
      assert MetricsCollector.get_latest() == metrics
    end
  end
end
