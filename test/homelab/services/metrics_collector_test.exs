defmodule Homelab.Services.MetricsCollectorTest do
  use ExUnit.Case, async: false

  alias Homelab.Services.MetricsCollector

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

    test "survives a poll cycle without crashing" do
      pid = start_supervised!({MetricsCollector, []})
      ref = Process.monitor(pid)
      send(pid, :poll)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 3_000
    end
  end
end
