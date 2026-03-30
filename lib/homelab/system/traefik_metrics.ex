defmodule Homelab.System.TraefikMetrics do
  @moduledoc """
  Scrapes Traefik's Prometheus `/metrics` endpoint and parses raw
  Prometheus text format into structured per-service traffic data.

  Traefik exposes metrics at `http://homelab-traefik:8080/metrics`
  on the `homelab-internal` network.
  """

  require Logger

  defp metrics_url do
    Application.get_env(:homelab, __MODULE__, [])[:metrics_url] ||
      "http://homelab-traefik:8080/metrics"
  end

  @doc """
  Fetches and parses all Traefik service metrics.
  Returns `{:ok, map}` keyed by service name, or `{:error, reason}`.
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
  Returns traffic stats for a specific deployment identified by its
  sanitized domain name (used as the Traefik router/service name).
  """
  def for_service(service_name) do
    case collect() do
      {:ok, metrics} -> Map.get(metrics, service_name, empty_stats())
      {:error, _} -> empty_stats()
    end
  end

  @doc """
  Returns aggregate stats across all tracked services.
  """
  def summary do
    case collect() do
      {:ok, metrics} when map_size(metrics) > 0 ->
        Enum.reduce(metrics, empty_stats(), fn {_svc, stats}, acc ->
          %{
            requests_total: acc.requests_total + stats.requests_total,
            requests_bytes_total: acc.requests_bytes_total + stats.requests_bytes_total,
            responses_bytes_total: acc.responses_bytes_total + stats.responses_bytes_total,
            error_count: acc.error_count + stats.error_count,
            services_count: acc.services_count + 1
          }
        end)

      {:ok, _} ->
        empty_stats()

      {:error, _} ->
        empty_stats()
    end
  end

  defp empty_stats do
    %{
      requests_total: 0,
      requests_bytes_total: 0,
      responses_bytes_total: 0,
      error_count: 0,
      services_count: 0
    }
  end

  defp parse_metrics(body) do
    body
    |> String.split("\n")
    |> Enum.reject(&(String.starts_with?(&1, "#") or &1 == ""))
    |> Enum.reduce(%{}, fn line, acc ->
      cond do
        String.starts_with?(line, "traefik_service_requests_total") ->
          parse_service_metric(line, acc, :requests_total)

        String.starts_with?(line, "traefik_service_requests_bytes_total") ->
          parse_service_metric(line, acc, :requests_bytes_total)

        String.starts_with?(line, "traefik_service_responses_bytes_total") ->
          parse_service_metric(line, acc, :responses_bytes_total)

        true ->
          acc
      end
    end)
    |> compute_error_counts()
  end

  defp parse_service_metric(line, acc, metric_key) do
    case extract_service_and_value(line) do
      {service, code, value} ->
        entry = Map.get(acc, service, empty_stats() |> Map.put(:status_breakdown, %{}))
        entry = Map.update!(entry, metric_key, &(&1 + value))

        entry =
          if metric_key == :requests_total and code do
            breakdown = Map.get(entry, :status_breakdown, %{})
            Map.put(entry, :status_breakdown, Map.update(breakdown, code, value, &(&1 + value)))
          else
            entry
          end

        Map.put(acc, service, entry)

      nil ->
        acc
    end
  end

  defp extract_service_and_value(line) do
    case Regex.run(~r/\{([^}]*)\}\s+([\d.e+\-]+)$/, line) do
      [_, labels_str, value_str] ->
        service = extract_label(labels_str, "service")
        code = extract_label(labels_str, "code")
        value = parse_number(value_str)

        if service do
          {service, code, value}
        else
          nil
        end

      _ ->
        nil
    end
  end

  defp extract_label(labels_str, key) do
    case Regex.run(~r/#{key}="([^"]*)"/, labels_str) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp parse_number(str) do
    case Float.parse(str) do
      {f, _} -> round(f)
      :error -> 0
    end
  end

  defp compute_error_counts(metrics) do
    Map.new(metrics, fn {service, stats} ->
      breakdown = Map.get(stats, :status_breakdown, %{})

      error_count =
        breakdown
        |> Enum.filter(fn {code, _} ->
          code_int = parse_number(code)
          code_int >= 400
        end)
        |> Enum.reduce(0, fn {_, count}, sum -> sum + count end)

      {service, Map.put(stats, :error_count, error_count)}
    end)
  end
end
