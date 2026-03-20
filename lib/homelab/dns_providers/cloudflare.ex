defmodule Homelab.DnsProviders.Cloudflare do
  @moduledoc """
  Cloudflare DNS provider for managing public DNS records.

  Uses the Cloudflare API v4 to create, update, delete, and list
  DNS records within zones. The `zone_id` parameter corresponds to
  the Cloudflare zone ID stored in `dns_zones.provider_zone_id`.
  """

  @behaviour Homelab.Behaviours.DnsProvider

  @base_url "https://api.cloudflare.com/client/v4"

  @impl true
  def driver_id, do: "cloudflare"

  @impl true
  def display_name, do: "Cloudflare DNS"

  @impl true
  def description, do: "Manage public DNS records via Cloudflare API"

  @impl true
  def scope, do: :public

  @impl true
  def list_records(zone_id) do
    with {:ok, token} <- require_token() do
      fetch_all_records(token, zone_id, 1, [])
    end
  end

  @impl true
  def create_record(zone_id, record) do
    with {:ok, token} <- require_token() do
      body = %{
        type: record[:type] || record["type"],
        name: record[:name] || record["name"],
        content: record[:value] || record["value"],
        ttl: record[:ttl] || record["ttl"] || 300,
        proxied: false
      }

      case Req.post("#{@base_url}/zones/#{zone_id}/dns_records",
             headers: auth_headers(token),
             json: body
           ) do
        {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
          {:ok, normalize_record(result)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  @impl true
  def update_record(zone_id, record_id, record) do
    with {:ok, token} <- require_token() do
      body = %{
        type: record[:type] || record["type"],
        name: record[:name] || record["name"],
        content: record[:value] || record["value"],
        ttl: record[:ttl] || record["ttl"] || 300,
        proxied: false
      }

      case Req.put("#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}",
             headers: auth_headers(token),
             json: body
           ) do
        {:ok, %Req.Response{status: 200, body: %{"result" => result}}} ->
          {:ok, normalize_record(result)}

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  @impl true
  def delete_record(zone_id, record_id) do
    with {:ok, token} <- require_token() do
      case Req.delete("#{@base_url}/zones/#{zone_id}/dns_records/#{record_id}",
             headers: auth_headers(token)
           ) do
        {:ok, %Req.Response{status: 200}} ->
          :ok

        {:ok, %Req.Response{status: status, body: body}} ->
          {:error, {:api_error, status, body}}

        {:error, reason} ->
          {:error, {:connection_error, reason}}
      end
    end
  end

  defp fetch_all_records(token, zone_id, page, acc) do
    case Req.get("#{@base_url}/zones/#{zone_id}/dns_records",
           headers: auth_headers(token),
           params: [page: page, per_page: 100]
         ) do
      {:ok, %Req.Response{status: 200, body: %{"result" => records, "result_info" => info}}} ->
        mapped = Enum.map(records, &normalize_record/1)
        all = acc ++ mapped
        total_pages = info["total_pages"] || 1

        if page < total_pages do
          fetch_all_records(token, zone_id, page + 1, all)
        else
          {:ok, all}
        end

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp normalize_record(r) do
    %{
      id: r["id"],
      name: r["name"],
      type: r["type"],
      value: r["content"],
      ttl: r["ttl"],
      proxied: r["proxied"]
    }
  end

  defp require_token do
    case Homelab.Settings.get("cloudflare_api_token") do
      nil -> {:error, :not_configured}
      token -> {:ok, token}
    end
  end

  defp auth_headers(token) do
    [{"authorization", "Bearer #{token}"}]
  end
end
