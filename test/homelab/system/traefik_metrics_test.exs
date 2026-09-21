defmodule Homelab.System.TraefikMetricsTest do
  use ExUnit.Case, async: false

  alias Homelab.System.TraefikMetrics
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    ApiServer.traefik_metrics(bypass)

    Application.put_env(:homelab, TraefikMetrics,
      metrics_url: "http://localhost:#{bypass.port}/metrics"
    )

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

    test "sums request counts across every code/method/protocol partition" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]

      # 120 + 30 + 5 + 2 + 9: one metric family split five ways by its labels.
      assert service.requests_total == 166
      assert service.status_breakdown == %{"200" => 150, "404" => 5, "500" => 2, "0" => 9}
    end

    test "computes error counts from 4xx and 5xx status codes" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]
      assert service.error_count == 7
    end

    test "an upgraded websocket (code 0) is not counted as an error" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]

      assert service.status_breakdown["0"] == 9
      assert service.error_count == 7
    end

    test "breaks requests down by method and protocol" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]

      assert service.method_breakdown == %{"GET" => 136, "POST" => 30}
      assert service.protocol_breakdown == %{"http" => 157, "websocket" => 9}
    end

    test "captures the latency histogram and its sum/count" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]

      assert service.duration_count == 157
      assert service.duration_seconds_sum == 15.7
      assert service.duration_buckets["0.1"] == 100
      assert service.duration_buckets["+Inf"] == 157
    end

    test "bytes counters are not confused with the request counter" do
      {:ok, metrics} = TraefikMetrics.collect()
      service = metrics["myapp@docker"]

      assert service.requests_bytes_total == 1_024_000
      assert service.responses_bytes_total == 5_120_000
    end
  end

  describe "lookup/2" do
    setup do
      {:ok, metrics} = TraefikMetrics.collect()
      {:ok, metrics: metrics}
    end

    test "finds a service by the bare router name the labels write", %{metrics: metrics} do
      # This is the whole point: nothing in the app can write "@docker" into a Traefik
      # label, so a UI holding a router name has only the bare half to look up with.
      assert TraefikMetrics.lookup(metrics, "myapp").requests_total == 166
    end

    test "finds a service by its provider-qualified name", %{metrics: metrics} do
      assert TraefikMetrics.lookup(metrics, "myapp@docker").requests_total == 166
    end

    test "returns empty stats for a service that is not there", %{metrics: metrics} do
      assert TraefikMetrics.lookup(metrics, "missing").requests_total == 0
      assert TraefikMetrics.lookup(metrics, "missing").status_breakdown == %{}
    end

    test "does not match a service that merely shares a prefix", %{metrics: metrics} do
      assert TraefikMetrics.lookup(metrics, "myap").requests_total == 0
    end
  end

  describe "match_keys/2" do
    test "returns the qualified key for a bare name" do
      {:ok, metrics} = TraefikMetrics.collect()
      assert TraefikMetrics.match_keys(metrics, "myapp") == ["myapp@docker"]
    end

    test "works against a plain list of recorded subject names" do
      subjects = ["myapp@docker", "otherapp@docker", "homelab@file"]
      assert TraefikMetrics.match_keys(subjects, "homelab") == ["homelab@file"]
      assert TraefikMetrics.match_keys(subjects, "nothing") == []
    end
  end

  describe "merge/1" do
    test "sums counters and merges breakdowns across a deployment's routers" do
      {:ok, metrics} = TraefikMetrics.collect()

      merged =
        TraefikMetrics.merge([
          TraefikMetrics.lookup(metrics, "myapp"),
          TraefikMetrics.lookup(metrics, "otherapp")
        ])

      assert merged.requests_total == 206
      assert merged.status_breakdown["200"] == 190
      assert merged.responses_bytes_total == 5_200_000
      assert merged.error_count == 7
    end

    test "merging nothing yields the empty shape" do
      assert TraefikMetrics.merge([]) == TraefikMetrics.empty_stats()
    end
  end

  describe "latency_histogram/1" do
    test "de-cumulates Prometheus buckets into labelled bands" do
      {:ok, metrics} = TraefikMetrics.collect()
      stats = TraefikMetrics.lookup(metrics, "myapp")

      assert TraefikMetrics.latency_histogram(stats) == [
               {"< 100ms", 100},
               {"100ms–300ms", 40},
               {"300ms–1.2s", 15},
               {"1.2s–5s", 2},
               {"> 5s", 0}
             ]
    end

    test "bands sum back to the total observation count" do
      {:ok, metrics} = TraefikMetrics.collect()
      stats = TraefikMetrics.lookup(metrics, "myapp")

      total = stats |> TraefikMetrics.latency_histogram() |> Enum.map(&elem(&1, 1)) |> Enum.sum()

      assert total == stats.duration_count
    end

    test "a service with no histogram has no bands" do
      {:ok, metrics} = TraefikMetrics.collect()
      assert TraefikMetrics.latency_histogram(TraefikMetrics.lookup(metrics, "otherapp")) == []
    end
  end

  describe "mean_latency_ms/1 and error_rate/1" do
    test "derives the mean from the sum and count, in milliseconds" do
      {:ok, metrics} = TraefikMetrics.collect()
      stats = TraefikMetrics.lookup(metrics, "myapp")

      assert_in_delta TraefikMetrics.mean_latency_ms(stats), 100.0, 0.01
    end

    test "a service that has served nothing has no mean" do
      assert TraefikMetrics.mean_latency_ms(TraefikMetrics.empty_stats()) == nil
    end

    test "error rate is a percentage of all requests" do
      {:ok, metrics} = TraefikMetrics.collect()
      stats = TraefikMetrics.lookup(metrics, "myapp")

      assert_in_delta TraefikMetrics.error_rate(stats), 7 / 166 * 100, 0.01
      assert TraefikMetrics.error_rate(TraefikMetrics.empty_stats()) == 0.0
    end
  end

  describe "for_service/1" do
    test "returns stats for a specific service" do
      stats = TraefikMetrics.for_service("myapp@docker")
      assert stats.requests_total > 0
    end

    test "accepts the bare router name too" do
      assert TraefikMetrics.for_service("myapp").requests_total > 0
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

  describe "when Traefik is unreachable" do
    test "collect reports the error", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, {:connection_error, _}} = TraefikMetrics.collect()
    end

    test "for_service degrades to empty stats rather than raising", %{bypass: bypass} do
      Bypass.down(bypass)
      assert TraefikMetrics.for_service("myapp").requests_total == 0
    end
  end
end
