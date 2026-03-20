defmodule Homelab.DnsProviders.Pihole do
  @moduledoc """
  Pi-hole DNS provider for managing internal/LAN DNS records.

  Fallback for users without UniFi infrastructure. Manages local DNS
  entries via Pi-hole's API. Requires a running Pi-hole instance
  (typically provisioned via `Homelab.Infrastructure`).
  """

  @behaviour Homelab.Behaviours.DnsProvider

  require Logger

  @impl true
  def driver_id, do: "pihole"

  @impl true
  def display_name, do: "Pi-hole"

  @impl true
  def description, do: "Manage internal DNS records via Pi-hole"

  @impl true
  def scope, do: :internal

  @impl true
  def list_records(zone_name) do
    with {:ok, config} <- require_config() do
      case Req.get("#{config.base_url}/api/dns/local/cname",
             headers: auth_headers(config)
           ) do
        {:ok, %Req.Response{status: 200, body: %{"data" => cnames}}} ->
          a_records = fetch_a_records(config)

          all =
            normalize_a_records(a_records, zone_name) ++
              normalize_cname_records(cnames, zone_name)

          {:ok, all}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  @impl true
  def create_record(_zone_name, record) do
    with {:ok, config} <- require_config() do
      type = String.upcase(to_string(record[:type] || record["type"]))
      name = record[:name] || record["name"]
      value = record[:value] || record["value"]

      {endpoint, body} = record_endpoint_and_body(type, name, value)

      case Req.post("#{config.base_url}/api/dns/local/#{endpoint}",
             headers: auth_headers(config),
             json: body
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 201] ->
          {:ok, %{id: "#{type}:#{name}", name: name, type: type, value: value, ttl: 300}}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  @impl true
  def update_record(zone_name, record_id, record) do
    with :ok <- delete_record(zone_name, record_id) do
      create_record(zone_name, record)
    end
  end

  @impl true
  def delete_record(_zone_name, record_id) do
    with {:ok, config} <- require_config() do
      [type, name] = String.split(record_id, ":", parts: 2)
      {endpoint, _body} = record_endpoint_and_body(type, name, "")

      case Req.delete("#{config.base_url}/api/dns/local/#{endpoint}/#{URI.encode(name)}",
             headers: auth_headers(config)
           ) do
        {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
        {:ok, %Req.Response{status: 404}} -> :ok
        {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
        {:error, reason} -> {:error, {:connection_error, reason}}
      end
    end
  end

  # --- Helpers ---

  defp fetch_a_records(config) do
    case Req.get("#{config.base_url}/api/dns/local/a",
           headers: auth_headers(config)
         ) do
      {:ok, %Req.Response{status: 200, body: %{"data" => records}}} -> records
      _ -> []
    end
  end

  defp normalize_a_records(records, zone_name) do
    records
    |> Enum.filter(&record_in_zone?(&1, zone_name))
    |> Enum.map(fn r ->
      %{
        id: "A:#{r["domain"] || r["name"]}",
        name: r["domain"] || r["name"],
        type: "A",
        value: r["ip"] || r["value"],
        ttl: 300
      }
    end)
  end

  defp normalize_cname_records(records, zone_name) do
    records
    |> Enum.filter(&record_in_zone?(&1, zone_name))
    |> Enum.map(fn r ->
      %{
        id: "CNAME:#{r["domain"] || r["name"]}",
        name: r["domain"] || r["name"],
        type: "CNAME",
        value: r["target"] || r["value"],
        ttl: 300
      }
    end)
  end

  defp record_in_zone?(record, zone_name) do
    domain = record["domain"] || record["name"] || record["key"] || ""
    String.ends_with?(domain, ".#{zone_name}") or domain == zone_name
  end

  defp record_endpoint_and_body("A", name, value) do
    {"a", %{"domain" => name, "ip" => value}}
  end

  defp record_endpoint_and_body("CNAME", name, value) do
    {"cname", %{"domain" => name, "target" => value}}
  end

  defp record_endpoint_and_body(type, name, value) do
    {"a", %{"domain" => name, "ip" => value, "type" => type}}
  end

  defp require_config do
    base_url = Homelab.Settings.get("pihole_url")
    api_key = Homelab.Settings.get("pihole_api_key")

    case {base_url, api_key} do
      {nil, _} -> {:error, :not_configured}
      {_, nil} -> {:error, :not_configured}
      _ -> {:ok, %{base_url: String.trim_trailing(base_url, "/"), api_key: api_key}}
    end
  end

  defp auth_headers(config) do
    [{"x-api-key", config.api_key}]
  end
end
