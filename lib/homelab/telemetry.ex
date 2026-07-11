defmodule Homelab.Telemetry do
  @moduledoc """
  Time-series telemetry: persists periodic metric snapshots into `metric_samples`
  and serves them back as series for charting.

  `Homelab.Services.MetricsCollector` calls `record_snapshot/2` on every poll and
  `prune/1` on a slow schedule. The dashboard/telemetry LiveViews read series via
  `series/1` and `host_series/2`.

  Not to be confused with `HomelabWeb.Telemetry`, which wires up the framework's
  `:telemetry` metrics for the Prometheus exporter.
  """

  import Ecto.Query

  alias Homelab.Repo
  alias Homelab.Telemetry.Sample

  @default_retention_days 7
  @default_window_minutes 30

  # --- Writing --------------------------------------------------------------

  @doc """
  Flattens a `MetricsCollector` snapshot into rows and bulk-inserts them.

  `combined` is the map broadcast on `"metrics:update"` (host metrics plus a
  `:traefik` sub-map and a `:docker` info map). Returns `{count, nil}` from
  `insert_all`, or `{0, nil}` when the snapshot yields no numeric samples.
  """
  def record_snapshot(combined, now \\ DateTime.utc_now()) when is_map(combined) do
    now = DateTime.truncate(now, :microsecond)

    case rows_from_snapshot(combined, now) do
      [] -> {0, nil}
      rows -> Repo.insert_all(Sample, rows)
    end
  end

  @doc """
  Pure transform: turns a snapshot map into a list of insertable sample rows.

  Only numeric values are emitted; missing or non-numeric fields are skipped so a
  partial snapshot (e.g. Docker unreachable) still records whatever it has.
  """
  def rows_from_snapshot(combined, %DateTime{} = now) when is_map(combined) do
    []
    |> host_rows(combined, now)
    |> disk_rows(combined, now)
    |> docker_rows(combined, now)
    |> traefik_rows(combined, now)
  end

  defp host_rows(rows, combined, now) do
    rows
    |> put_row(now, "host", nil, "cpu_percent", combined[:cpu_percent])
    |> put_row(now, "host", nil, "memory_percent", combined[:memory_percent])
    |> put_row(now, "host", nil, "memory_used", combined[:memory_used])
    |> put_row(now, "host", nil, "memory_total", combined[:memory_total])
  end

  defp disk_rows(rows, combined, now) do
    combined
    |> Map.get(:disk, [])
    |> List.wrap()
    |> Enum.reduce(rows, fn
      %{mount: mount} = d, acc ->
        acc
        |> put_row(now, "host", "disk:" <> to_string(mount), "disk_percent", d[:percent])
        |> put_row(now, "host", "disk:" <> to_string(mount), "disk_used", d[:used])

      _, acc ->
        acc
    end)
  end

  defp docker_rows(rows, combined, now) do
    docker = Map.get(combined, :docker, %{})

    rows
    |> put_row(now, "docker", nil, "containers_total", docker["Containers"])
    |> put_row(now, "docker", nil, "containers_running", docker["ContainersRunning"])
    |> put_row(now, "docker", nil, "containers_stopped", docker["ContainersStopped"])
    |> put_row(now, "docker", nil, "images", docker["Images"])
  end

  defp traefik_rows(rows, combined, now) do
    combined
    |> Map.get(:traefik, %{})
    |> Enum.reduce(rows, fn
      {service, stats}, acc when is_map(stats) ->
        acc
        |> put_row(now, "traefik", to_string(service), "requests_total", stats[:requests_total])
        |> put_row(now, "traefik", to_string(service), "error_count", stats[:error_count])
        |> put_row(
          now,
          "traefik",
          to_string(service),
          "requests_bytes_total",
          stats[:requests_bytes_total]
        )
        |> put_row(
          now,
          "traefik",
          to_string(service),
          "responses_bytes_total",
          stats[:responses_bytes_total]
        )

      _, acc ->
        acc
    end)
  end

  # Appends a row only when the value is numeric; keeps insert_all rows uniform.
  defp put_row(rows, now, source, subject, metric, value) when is_number(value) do
    [
      %{recorded_at: now, source: source, subject: subject, metric: metric, value: value / 1}
      | rows
    ]
  end

  defp put_row(rows, _now, _source, _subject, _metric, _value), do: rows

  # --- Reading --------------------------------------------------------------

  @doc """
  Returns a single metric series as `[%{recorded_at: DateTime, value: float}]`
  ordered oldest-first.

  Options:
    * `:source`  — required, e.g. `"host"`
    * `:metric`  — required, e.g. `"cpu_percent"`
    * `:subject` — dimension; omit or pass `nil` for host-wide series
    * `:minutes` — look-back window (default #{@default_window_minutes})
    * `:since`   — explicit `%DateTime{}` lower bound (overrides `:minutes`)
    * `:limit`   — cap on returned points (most recent kept)
  """
  def series(opts) do
    source = Keyword.fetch!(opts, :source)
    metric = Keyword.fetch!(opts, :metric)
    subject = Keyword.get(opts, :subject)
    since = since_bound(opts)

    query =
      from s in Sample,
        where: s.source == ^source and s.metric == ^metric and s.recorded_at >= ^since,
        select: %{recorded_at: s.recorded_at, value: s.value},
        order_by: [asc: s.recorded_at]

    query = subject_where(query, subject)

    query =
      case Keyword.get(opts, :limit) do
        nil -> query
        limit when is_integer(limit) -> limit_recent(query, limit)
      end

    Repo.all(query)
  end

  @doc "Convenience for host-wide series (subject `nil`)."
  def host_series(metric, opts \\ []) do
    series(Keyword.merge([source: "host", metric: metric], opts))
  end

  @doc """
  Lists the distinct subjects recorded for a `source`/`metric` within the window
  — e.g. every Traefik service, or every disk mount, seen recently.
  """
  def subjects(source, metric, opts \\ []) do
    since = since_bound(opts)

    Repo.all(
      from s in Sample,
        where: s.source == ^source and s.metric == ^metric and s.recorded_at >= ^since,
        where: not is_nil(s.subject),
        distinct: true,
        select: s.subject,
        order_by: [asc: s.subject]
    )
  end

  # A subject filter that distinguishes "host-wide" (IS NULL) from a named subject.
  defp subject_where(query, nil), do: from(s in query, where: is_nil(s.subject))
  defp subject_where(query, subject), do: from(s in query, where: s.subject == ^subject)

  # Take the most recent `limit` points, then re-sort ascending for charting.
  defp limit_recent(query, limit) do
    recent = from(s in exclude(query, :order_by), order_by: [desc: s.recorded_at], limit: ^limit)
    from s in subquery(recent), order_by: [asc: s.recorded_at]
  end

  defp since_bound(opts) do
    case Keyword.get(opts, :since) do
      %DateTime{} = since ->
        since

      _ ->
        minutes = Keyword.get(opts, :minutes, @default_window_minutes)
        DateTime.add(DateTime.utc_now(), -minutes * 60, :second)
    end
  end

  # --- Retention ------------------------------------------------------------

  @doc """
  Deletes samples older than the retention window. Returns `{deleted_count, nil}`.
  Pass `cutoff` to override; defaults to `now - retention_days`.
  """
  def prune(cutoff \\ nil) do
    cutoff = cutoff || DateTime.add(DateTime.utc_now(), -retention_days() * 86_400, :second)
    Repo.delete_all(from s in Sample, where: s.recorded_at < ^cutoff)
  end

  @doc "Configured retention window in days (`config :homelab, Homelab.Telemetry, retention_days:`)."
  def retention_days do
    Application.get_env(:homelab, __MODULE__, [])
    |> Keyword.get(:retention_days, @default_retention_days)
  end
end
