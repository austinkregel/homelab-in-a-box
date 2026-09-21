defmodule Homelab.System.TraefikMetrics do
  @moduledoc """
  Scrapes Traefik's Prometheus `/metrics` endpoint and parses raw
  Prometheus text format into structured per-service traffic data.

  Traefik exposes metrics at `http://homelab-traefik:8080/metrics`
  on the `homelab-iab-internal` network.

  ## Service names are provider-qualified

  Every service in Traefik's metrics is keyed by a PROVIDER-QUALIFIED name:
  `myapp@docker` for a service discovered from container labels, `homelab@file`
  for one declared in a static file. The Traefik labels this app writes
  (`Homelab.Deployments.SpecBuilder.route_names/1`) only ever name the bare part
  — `myapp` — because the provider suffix is Traefik's own bookkeeping and cannot
  be written into a label.

  So a caller holding a router name can never match a metrics key by equality.
  Every lookup goes through `lookup/2`, which compares the part before the `@`.

  ## Counters are cumulative

  Each value is a counter accumulated since the Traefik process started, not a
  rate and not a windowed total. A caller wanting "requests in the last hour"
  must diff two samples — `Homelab.Telemetry.delta_series/1` does that against
  the persisted time-series.
  """

  require Logger

  # {metric family, what it contributes}. A family is matched with its opening
  # brace attached so `..._requests_total` can never swallow a longer name that
  # merely starts the same way.
  @families [
    {"traefik_service_requests_bytes_total", :requests_bytes},
    {"traefik_service_responses_bytes_total", :responses_bytes},
    {"traefik_service_requests_total", :requests},
    {"traefik_service_request_duration_seconds_bucket", :duration_bucket},
    {"traefik_service_request_duration_seconds_sum", :duration_sum},
    {"traefik_service_request_duration_seconds_count", :duration_count}
  ]

  defp metrics_url do
    Application.get_env(:homelab, __MODULE__, [])[:metrics_url] ||
      "http://homelab-traefik:8080/metrics"
  end

  @doc """
  Fetches and parses all Traefik service metrics.
  Returns `{:ok, map}` keyed by provider-qualified service name, or `{:error, reason}`.
  """
  def collect do
    case Req.get(metrics_url(), retry: false, receive_timeout: 5_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_binary(body) ->
        {:ok, parse_metrics(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Stats for one service, by bare or provider-qualified name.

  Scrapes on every call; callers that already hold a collected map (a
  `"metrics:update"` broadcast, `MetricsCollector.get_latest/0`) should use
  `lookup/2` instead of paying for a second HTTP round trip.
  """
  def for_service(service_name) do
    case collect() do
      {:ok, metrics} -> lookup(metrics, service_name)
      {:error, _} -> empty_stats()
    end
  end

  @doc """
  Finds a service in a collected map by bare name (`"myapp"`) or by its
  qualified name (`"myapp@docker"`), returning empty stats when absent.

  This is the ONLY correct way to read a service out of `collect/0`: the keys
  carry a provider suffix that no caller can predict, so `Map.get/2` with a
  router name silently misses every time and reports a live service as idle.
  """
  def lookup(metrics, service_name) when is_map(metrics) and is_binary(service_name) do
    case Map.fetch(metrics, service_name) do
      {:ok, stats} ->
        stats

      :error ->
        bare = bare_name(service_name)

        Enum.find_value(metrics, empty_stats(), fn {key, stats} ->
          bare_name(key) == bare && stats
        end)
    end
  end

  def lookup(_metrics, _service_name), do: empty_stats()

  @doc """
  The keys of `metrics` (or any list of qualified names) that belong to
  `service_name`, ignoring the provider suffix.

  Used to line a router name up with the `subject` column in the persisted
  time-series, where names are stored exactly as Traefik reported them.
  """
  def match_keys(keys, service_name) when is_binary(service_name) do
    bare = bare_name(service_name)

    keys
    |> enumerable_keys()
    |> Enum.filter(&(bare_name(&1) == bare))
  end

  defp enumerable_keys(keys) when is_map(keys), do: Map.keys(keys)
  defp enumerable_keys(keys) when is_list(keys), do: keys
  defp enumerable_keys(_), do: []

  @doc "Strips the `@provider` suffix Traefik appends to every service name."
  def bare_name(name) when is_binary(name), do: name |> String.split("@") |> hd()
  def bare_name(name), do: name

  @doc """
  Sums a list of per-service stats into one, for a deployment whose labels
  define several routers (a second host, or a path routed to another port).
  Breakdowns and histogram buckets are merged key-wise.
  """
  def merge(stats_list) do
    stats_list
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.reduce(empty_stats(), fn stats, acc ->
      %{
        requests_total: acc.requests_total + get(stats, :requests_total, 0),
        requests_bytes_total: acc.requests_bytes_total + get(stats, :requests_bytes_total, 0),
        responses_bytes_total: acc.responses_bytes_total + get(stats, :responses_bytes_total, 0),
        error_count: acc.error_count + get(stats, :error_count, 0),
        status_breakdown: sum_maps(acc.status_breakdown, get(stats, :status_breakdown, %{})),
        method_breakdown: sum_maps(acc.method_breakdown, get(stats, :method_breakdown, %{})),
        protocol_breakdown:
          sum_maps(acc.protocol_breakdown, get(stats, :protocol_breakdown, %{})),
        duration_seconds_sum: acc.duration_seconds_sum + get(stats, :duration_seconds_sum, 0.0),
        duration_count: acc.duration_count + get(stats, :duration_count, 0),
        duration_buckets: sum_maps(acc.duration_buckets, get(stats, :duration_buckets, %{}))
      }
    end)
  end

  @doc """
  Returns aggregate stats across all tracked services, plus a `:services_count`.
  """
  def summary do
    case collect() do
      {:ok, metrics} when map_size(metrics) > 0 ->
        metrics
        |> Map.values()
        |> merge()
        |> Map.put(:services_count, map_size(metrics))

      _ ->
        Map.put(empty_stats(), :services_count, 0)
    end
  end

  @doc """
  Mean time to serve a request, in milliseconds, or `nil` when nothing has been
  served. This is the lifetime mean — every request since Traefik started
  weighs the same, so a recent slowdown barely moves it.
  """
  def mean_latency_ms(stats) do
    count = get(stats, :duration_count, 0)

    if count > 0 do
      get(stats, :duration_seconds_sum, 0.0) / count * 1000
    end
  end

  @doc """
  The latency histogram as ordered, NON-cumulative `{label, count}` pairs.

  Prometheus buckets are cumulative (`le="0.3"` counts everything at or below
  300ms, including what `le="0.1"` already counted), so each band is the
  difference from the one below it. Bounds are read from the data rather than
  hardcoded — they are a Traefik setting, and a tuned deployment reports
  different ones.
  """
  def latency_histogram(stats) do
    buckets = get(stats, :duration_buckets, %{})

    {finite, infinite} =
      buckets
      |> Enum.map(fn {le, count} -> {bucket_bound(le), count} end)
      |> Enum.split_with(fn {bound, _} -> bound != :infinity end)

    finite = Enum.sort_by(finite, &elem(&1, 0))
    total = infinite |> Enum.map(&elem(&1, 1)) |> Enum.max(fn -> 0 end)

    case finite do
      [] ->
        []

      _ ->
        {bands, {last_bound, last_cumulative}} =
          Enum.map_reduce(finite, {nil, 0}, fn {bound, cumulative}, {lower, running} ->
            {{band_label(lower, bound), max(cumulative - running, 0)}, {bound, cumulative}}
          end)

        bands ++ [{band_label(last_bound, :infinity), max(total - last_cumulative, 0)}]
    end
  end

  @doc "Requests that ended in a 4xx or 5xx, as a percentage of all requests."
  def error_rate(stats) do
    total = get(stats, :requests_total, 0)
    if total > 0, do: get(stats, :error_count, 0) / total * 100, else: 0.0
  end

  @doc "A zeroed stats map, the shape every other function here returns."
  def empty_stats do
    %{
      requests_total: 0,
      requests_bytes_total: 0,
      responses_bytes_total: 0,
      error_count: 0,
      status_breakdown: %{},
      method_breakdown: %{},
      protocol_breakdown: %{},
      duration_seconds_sum: 0.0,
      duration_count: 0,
      duration_buckets: %{}
    }
  end

  # --- Parsing --------------------------------------------------------------

  defp parse_metrics(body) do
    body
    |> String.split("\n")
    |> Enum.reduce(%{}, &parse_line/2)
    |> Map.new(fn {service, stats} -> {service, put_error_count(stats)} end)
  end

  defp parse_line(line, acc) do
    line = String.trim(line)

    cond do
      line == "" or String.starts_with?(line, "#") ->
        acc

      true ->
        case family(line) do
          nil -> acc
          kind -> apply_sample(acc, line, kind)
        end
    end
  end

  defp family(line) do
    Enum.find_value(@families, fn {prefix, kind} ->
      String.starts_with?(line, prefix <> "{") && kind
    end)
  end

  defp apply_sample(acc, line, kind) do
    case Regex.run(~r/\{([^}]*)\}\s+([^\s]+)$/, line) do
      [_, labels_str, value_str] ->
        labels = parse_labels(labels_str)

        case labels["service"] do
          nil ->
            acc

          service ->
            Map.put(
              acc,
              service,
              sample(Map.get(acc, service, empty_stats()), kind, labels, value_str)
            )
        end

      _ ->
        acc
    end
  end

  defp sample(stats, :requests, labels, value_str) do
    n = round(parse_float(value_str))

    stats
    |> Map.update!(:requests_total, &(&1 + n))
    |> bump(:status_breakdown, labels["code"], n)
    |> bump(:method_breakdown, labels["method"], n)
    |> bump(:protocol_breakdown, labels["protocol"], n)
  end

  defp sample(stats, :requests_bytes, _labels, value_str),
    do: Map.update!(stats, :requests_bytes_total, &(&1 + round(parse_float(value_str))))

  defp sample(stats, :responses_bytes, _labels, value_str),
    do: Map.update!(stats, :responses_bytes_total, &(&1 + round(parse_float(value_str))))

  defp sample(stats, :duration_sum, _labels, value_str),
    do: Map.update!(stats, :duration_seconds_sum, &(&1 + parse_float(value_str)))

  defp sample(stats, :duration_count, _labels, value_str),
    do: Map.update!(stats, :duration_count, &(&1 + round(parse_float(value_str))))

  defp sample(stats, :duration_bucket, labels, value_str),
    do: bump(stats, :duration_buckets, labels["le"], round(parse_float(value_str)))

  defp bump(stats, _key, nil, _n), do: stats

  defp bump(stats, key, label, n) do
    Map.update!(stats, key, &Map.update(&1, label, n, fn existing -> existing + n end))
  end

  defp parse_labels(labels_str) do
    ~r/([a-zA-Z_][a-zA-Z0-9_]*)="([^"]*)"/
    |> Regex.scan(labels_str)
    |> Map.new(fn [_, key, value] -> {key, value} end)
  end

  defp parse_float(str) do
    case Float.parse(str) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  # A 4xx/5xx is an error; the `code="0"` Traefik records for a websocket that
  # never produced an HTTP status is not, and neither is a 3xx redirect.
  defp put_error_count(stats) do
    error_count =
      Enum.reduce(stats.status_breakdown, 0, fn {code, count}, sum ->
        case Integer.parse(to_string(code)) do
          {n, _} when n >= 400 -> sum + count
          _ -> sum
        end
      end)

    Map.put(stats, :error_count, error_count)
  end

  # --- Histogram helpers ----------------------------------------------------

  defp bucket_bound("+Inf"), do: :infinity

  defp bucket_bound(le) do
    case Float.parse(to_string(le)) do
      {f, _} -> f
      :error -> :infinity
    end
  end

  defp band_label(nil, upper), do: "< " <> duration_label(upper)
  defp band_label(lower, :infinity), do: "> " <> duration_label(lower)
  defp band_label(lower, upper), do: duration_label(lower) <> "–" <> duration_label(upper)

  defp duration_label(seconds) when is_number(seconds) and seconds < 1,
    do: "#{round(seconds * 1000)}ms"

  defp duration_label(seconds) when is_number(seconds),
    do: "#{:erlang.float_to_binary(seconds * 1.0, decimals: 1) |> String.replace(".0", "")}s"

  defp duration_label(_), do: "∞"

  # --- Small helpers --------------------------------------------------------

  defp get(stats, key, default) when is_map(stats), do: Map.get(stats, key) || default
  defp get(_stats, _key, default), do: default

  defp sum_maps(a, b) when is_map(a) and is_map(b) do
    Enum.reduce(b, a, fn {key, value}, acc -> Map.update(acc, key, value, &(&1 + value)) end)
  end

  defp sum_maps(a, _b), do: a
end
