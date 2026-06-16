defmodule Homelab.Catalog.HealthCheck do
  @moduledoc """
  Schema and validation for `AppTemplate.health_check` (decision §8).
  """

  @types ~w(http exec tcp)

  @spec validate(map() | nil) :: :ok | {:error, [String.t()]}
  def validate(nil), do: :ok

  def validate(%{} = hc) when map_size(hc) == 0, do: :ok

  def validate(%{} = hc) do
    errors = []

    errors =
      case hc["type"] || hc[:type] do
        t when t in @types -> errors
        nil -> ["health_check.type is required"]
        other -> ["health_check.type must be one of #{inspect(@types)}, got #{inspect(other)}"]
      end

    errors =
      case hc["timeout_seconds"] || hc[:timeout_seconds] do
        n when is_integer(n) and n > 0 -> errors
        nil -> errors ++ ["health_check.timeout_seconds is required"]
        _ -> errors ++ ["health_check.timeout_seconds must be a positive integer"]
      end

    errors =
      case hc["retries"] || hc[:retries] do
        n when is_integer(n) and n >= 0 -> errors
        nil -> errors ++ ["health_check.retries is required"]
        _ -> errors ++ ["health_check.retries must be a non-negative integer"]
      end

    errors =
      case hc["interval_seconds"] || hc[:interval_seconds] do
        n when is_integer(n) and n > 0 -> errors
        nil -> errors
        _ -> errors ++ ["health_check.interval_seconds must be a positive integer"]
      end

    type = hc["type"] || hc[:type]

    errors =
      case type do
        "http" ->
          if present?(hc, "endpoint") || present?(hc, :endpoint),
            do: errors,
            else: errors ++ ["health_check.endpoint is required for http type"]

        "exec" ->
          cmd = hc["command"] || hc[:command]

          if is_list(cmd) and cmd != [],
            do: errors,
            else: errors ++ ["health_check.command must be a non-empty list for exec type"]

        "tcp" ->
          if present?(hc, "endpoint") || present?(hc, :endpoint),
            do: errors,
            else: errors ++ ["health_check.endpoint is required for tcp type"]

        _ ->
          errors
      end

    if errors == [], do: :ok, else: {:error, errors}
  end

  defp present?(map, key), do: Map.has_key?(map, key) and map[key] not in [nil, ""]
end
