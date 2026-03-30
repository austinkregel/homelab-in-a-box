defmodule Homelab.System.TraefikMetricsTest do
  use ExUnit.Case, async: false

  alias Homelab.System.TraefikMetrics
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    ApiServer.traefik_metrics(bypass)

    Application.put_env(:homelab, TraefikMetrics, metrics_url: "http://localhost:#{bypass.port}/metrics")
    on_exit(fn -> Application.delete_env(:homelab, TraefikMetrics) end)

    {:ok, bypass: bypass}
  end

  describe "collect/0" do
    test "fetches and parses Prometheus metrics" do
      {:ok, metrics} = TraefikMetrics.collect()
      assert is_map(metrics)
      assert map_size(metrics) > 0

      service = metrics["myapp@docker"]
      assert service != nil
      assert service.requests_total > 0
    end

    test "parses request counts by status code" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]
      assert service.requests_total == 157
    end

    test "computes error counts from 4xx and 5xx status codes" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]
      assert service.error_count == 7
    end
  end

  describe "for_service/1" do
    test "returns stats for a specific service" do
      stats = TraefikMetrics.for_service("myapp@docker")
      assert stats.requests_total > 0
    end

    test "returns empty stats for unknown service" do
      stats = TraefikMetrics.for_service("unknown@docker")
      assert stats.requests_total == 0
    end
  end

  describe "summary/0" do
    test "returns aggregate stats" do
      summary = TraefikMetrics.summary()
      assert summary.requests_total > 0
      assert summary.services_count > 0
    end
  end
end
