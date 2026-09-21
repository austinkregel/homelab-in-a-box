defmodule Homelab.TelemetryTest do
  use Homelab.DataCase, async: true

  alias Homelab.Telemetry

  @snapshot %{
    cpu_percent: 42.5,
    memory_percent: 60.0,
    memory_used: 8_000_000_000,
    memory_total: 16_000_000_000,
    disk: [
      %{mount: "/", total: 100, used: 55, percent: 55.0},
      %{mount: "/data", total: 200, used: 20, percent: 10.0}
    ],
    docker: %{"Containers" => 12, "ContainersRunning" => 9, "Images" => 30},
    traefik: %{
      "app-example-com" => %{
        requests_total: 1234,
        error_count: 7,
        requests_bytes_total: 999,
        responses_bytes_total: 888
      }
    }
  }

  describe "rows_from_snapshot/2" do
    test "emits host, disk, docker, and traefik rows" do
      now = DateTime.utc_now()
      rows = Telemetry.rows_from_snapshot(@snapshot, now)

      metrics = MapSet.new(rows, & &1.metric)
      assert "cpu_percent" in metrics
      assert "memory_percent" in metrics
      assert "disk_percent" in metrics
      assert "containers_running" in metrics
      assert "requests_total" in metrics

      # Two mounts -> two disk_percent rows, each tagged by subject.
      disk = Enum.filter(rows, &(&1.metric == "disk_percent"))
      assert Enum.map(disk, & &1.subject) |> Enum.sort() == ["disk:/", "disk:/data"]

      # Every row carries the timestamp and a float value.
      assert Enum.all?(rows, &(&1.recorded_at == DateTime.truncate(now, :microsecond)))
      assert Enum.all?(rows, &is_float(&1.value))
    end

    test "skips non-numeric and missing fields without crashing" do
      partial = %{cpu_percent: 10.0, memory_percent: nil, docker: %{}, disk: []}
      rows = Telemetry.rows_from_snapshot(partial, DateTime.utc_now())

      assert Enum.map(rows, & &1.metric) == ["cpu_percent"]
    end
  end

  describe "record_snapshot/2 and series/1" do
    test "persists a snapshot and reads a host series back in time order" do
      t0 = DateTime.utc_now() |> DateTime.add(-60, :second)
      t1 = DateTime.utc_now()

      Telemetry.record_snapshot(%{cpu_percent: 20.0}, t0)
      Telemetry.record_snapshot(%{cpu_percent: 80.0}, t1)

      series = Telemetry.host_series("cpu_percent", minutes: 30)
      assert Enum.map(series, & &1.value) == [20.0, 80.0]
    end

    test "distinguishes host-wide (nil subject) from a named subject" do
      Telemetry.record_snapshot(@snapshot)

      root =
        Telemetry.series(source: "host", subject: "disk:/", metric: "disk_percent", minutes: 30)

      assert Enum.map(root, & &1.value) == [55.0]

      # A host-wide query must not pick up subject-scoped disk rows.
      assert Telemetry.host_series("disk_percent", minutes: 30) == []
    end

    test "respects the time window" do
      old = DateTime.utc_now() |> DateTime.add(-3600, :second)
      Telemetry.record_snapshot(%{cpu_percent: 5.0}, old)

      assert Telemetry.host_series("cpu_percent", minutes: 30) == []
      assert length(Telemetry.host_series("cpu_percent", minutes: 120)) == 1
    end

    test "limit keeps the most recent points, still ascending" do
      base = DateTime.utc_now() |> DateTime.add(-100, :second)

      for i <- 0..9 do
        Telemetry.record_snapshot(%{cpu_percent: i * 1.0}, DateTime.add(base, i, :second))
      end

      series = Telemetry.host_series("cpu_percent", minutes: 30, limit: 3)
      assert Enum.map(series, & &1.value) == [7.0, 8.0, 9.0]
    end
  end

  describe "deltas/1 and delta_series/1" do
    test "turns a running counter into what happened in each interval" do
      base = DateTime.utc_now() |> DateTime.add(-60, :second)

      series = [
        %{recorded_at: base, value: 100.0},
        %{recorded_at: DateTime.add(base, 10, :second), value: 130.0},
        %{recorded_at: DateTime.add(base, 20, :second), value: 131.0}
      ]

      assert Enum.map(Telemetry.deltas(series), & &1.value) == [30.0, 1.0]
      assert Enum.map(Telemetry.deltas(series), & &1.seconds) == [10, 10]
    end

    test "the first sample is dropped — it has nothing to diff against" do
      point = %{recorded_at: DateTime.utc_now(), value: 5.0}

      assert Telemetry.deltas([point]) == []
      assert Telemetry.deltas([]) == []
    end

    test "a counter reset records zero rather than a huge negative spike" do
      base = DateTime.utc_now() |> DateTime.add(-60, :second)

      # Traefik restarted between the second and third sample, so its counters
      # went back to zero. The traffic served before the restart is simply gone.
      series = [
        %{recorded_at: base, value: 900.0},
        %{recorded_at: DateTime.add(base, 10, :second), value: 1000.0},
        %{recorded_at: DateTime.add(base, 20, :second), value: 12.0},
        %{recorded_at: DateTime.add(base, 30, :second), value: 20.0}
      ]

      assert Enum.map(Telemetry.deltas(series), & &1.value) == [100.0, 0, 8.0]
    end

    test "delta_series reads a persisted counter and diffs it" do
      base = DateTime.utc_now() |> DateTime.add(-100, :second)

      for {offset, total} <- [{0, 10}, {10, 25}, {20, 60}] do
        Telemetry.record_snapshot(
          %{traefik: %{"app@docker" => %{requests_total: total}}},
          DateTime.add(base, offset, :second)
        )
      end

      deltas =
        Telemetry.delta_series(
          source: "traefik",
          subject: "app@docker",
          metric: "requests_total",
          minutes: 30
        )

      assert Enum.map(deltas, & &1.value) == [15.0, 35.0]
      assert Telemetry.delta_total(deltas) == 50.0
    end

    test "delta_total of an empty window is zero, not an error" do
      assert Telemetry.delta_total([]) == 0
    end
  end

  describe "traefik latency rows" do
    test "records the duration sum and count so a window mean can be derived" do
      rows =
        Telemetry.rows_from_snapshot(
          %{
            traefik: %{
              "app@docker" => %{
                requests_total: 10,
                duration_seconds_sum: 1.5,
                duration_count: 10
              }
            }
          },
          DateTime.utc_now()
        )

      by_metric = Map.new(rows, &{&1.metric, &1.value})

      # A stored MEAN could not be diffed across a window; a sum and a count can.
      assert by_metric["duration_seconds_sum"] == 1.5
      assert by_metric["duration_count"] == 10.0
    end
  end

  describe "subjects/3" do
    test "lists distinct subjects for a source/metric in the window" do
      Telemetry.record_snapshot(@snapshot)

      assert Telemetry.subjects("host", "disk_percent", minutes: 30) == ["disk:/", "disk:/data"]
      assert Telemetry.subjects("traefik", "requests_total", minutes: 30) == ["app-example-com"]
    end
  end

  describe "prune/1" do
    test "deletes samples older than the cutoff" do
      old = DateTime.utc_now() |> DateTime.add(-10_000, :second)
      recent = DateTime.utc_now()

      Telemetry.record_snapshot(%{cpu_percent: 1.0}, old)
      Telemetry.record_snapshot(%{cpu_percent: 2.0}, recent)

      cutoff = DateTime.add(DateTime.utc_now(), -3600, :second)
      {deleted, _} = Telemetry.prune(cutoff)

      assert deleted == 1
      assert Enum.map(Telemetry.host_series("cpu_percent", minutes: 200), & &1.value) == [2.0]
    end
  end

  test "retention_days/0 defaults to 7" do
    assert Telemetry.retention_days() == 7
  end
end
