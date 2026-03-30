defmodule Homelab.System.MetricsTest do
  use ExUnit.Case, async: true

  alias Homelab.System.Metrics

  describe "collect/0" do
    test "returns a map with expected keys" do
      result = Metrics.collect()

      assert is_map(result)
      assert Map.has_key?(result, :cpu_percent)
      assert Map.has_key?(result, :memory_total)
      assert Map.has_key?(result, :memory_used)
      assert Map.has_key?(result, :memory_percent)
      assert Map.has_key?(result, :disk)
      assert Map.has_key?(result, :docker)
    end

    test "returns numeric cpu_percent" do
      result = Metrics.collect()
      assert is_number(result.cpu_percent)
    end

    test "returns numeric memory values" do
      result = Metrics.collect()
      assert is_integer(result.memory_total) or result.memory_total == 0
      assert is_integer(result.memory_used) or result.memory_used == 0
      assert is_number(result.memory_percent)
    end

    test "returns disk as a list" do
      result = Metrics.collect()
      assert is_list(result.disk)
    end

    test "returns docker as a map" do
      result = Metrics.collect()
      assert is_map(result.docker)
    end
  end
end
