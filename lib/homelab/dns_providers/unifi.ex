defmodule Homelab.DnsProviders.Unifi do
  @moduledoc """
  UniFi Network DNS provider for managing internal/LAN DNS records.

  Supports two API versions with auto-detection:

  - **Legacy API** (UniFi Network 8.x+):
    `/proxy/network/v2/api/site/{site}/static-dns`
  - **New API** (UniFi Network 10.1+):
    `/proxy/network/integration/v1/sites/{siteId}/dns/policies`

  UniFi stores records flat (no zone concept). We filter by domain
  suffix to simulate zone-based management.
  """

  @behaviour Homelab.Behaviours.DnsProvider

  require Logger

  @impl true
  def driver_id, do: "unifi"

  @impl true
  def display_name, do: "UniFi Network"

  @impl true
  def description, do: "Manage internal DNS records on your UniFi gateway"

  @impl true
  def scope, do: :internal

  @impl true
  def list_records(zone_name) do
    with {:ok, config} <- require_config(),
         {_version, resolved} <- detect_api_version(config) do
      case resolved do
        %{api_version: "new"} -> new_api_list(resolved, zone_name)
        _ -> legacy_api_list(resolved, zone_name)
      end
    end
  end

  @impl true
  def create_record(zone_name, record) do
    with {:ok, config} <- require_config(),
         {_version, resolved} <- detect_api_version(config) do
      case resolved do
        %{api_version: "new"} -> new_api_create(resolved, zone_name, record)
        _ -> legacy_api_create(resolved, zone_name, record)
      end
    end
  end

  @impl true
  def update_record(zone_name, record_id, record) do
    with {:ok, config} <- require_config(),
         {_version, resolved} <- detect_api_version(config) do
      case resolved do
        %{api_version: "new"} -> new_api_update(resolved, record_id, record)
        _ -> legacy_api_update(resolved, zone_name, record_id, record)
      end
    end
  end

  @impl true
  def delete_record(zone_name, record_id) do
    with {:ok, config} <- require_config(),
         {_version, resolved} <- detect_api_version(config) do
      case resolved do
        %{api_version: "new"} -> new_api_delete(resolved, record_id)
        _ -> legacy_api_delete(resolved, zone_name, record_id)
      end
    end
  end

  # --- New API (UniFi Network 10.1+) ---

  defp new_api_base(config),
    do: "#{config.host}/proxy/network/integration/v1/sites/#{config.site}"

  defp new_api_list(config, zone_name) do
    case api_get("#{new_api_base(config)}/dns/policies", config) do
      {:ok, %Req.Response{status: 200, body: policies}} when is_list(policies) ->
        records =
          policies
          |> Enum.filter(&record_in_zone?(&1, zone_name))
          |> Enum.map(&normalize_new_api_record/1)

        {:ok, records}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp new_api_create(config, zone_name, record) do
    fqdn = build_fqdn(record, zone_name)

    body = %{
      "record_type" => record[:type] || record["type"],
      "key" => fqdn,
      "value" => record[:value] || record["value"],
      "ttl" => record[:ttl] || record["ttl"] || 300,
      "enabled" => true
    }

    case api_post("#{new_api_base(config)}/dns/policies", body, config) do
      {:ok, %Req.Response{status: status, body: result}} when status in [200, 201] ->
        {:ok, normalize_new_api_record(result)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp new_api_update(config, record_id, record) do
    body =
      %{}
      |> maybe_put("value", record[:value] || record["value"])
      |> maybe_put("ttl", record[:ttl] || record["ttl"])
      |> maybe_put("record_type", record[:type] || record["type"])
      |> Map.put("enabled", true)

    case api_put("#{new_api_base(config)}/dns/policies/#{record_id}", body, config) do
      {:ok, %Req.Response{status: 200, body: result}} ->
        {:ok, normalize_new_api_record(result)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp new_api_delete(config, record_id) do
    case api_delete("#{new_api_base(config)}/dns/policies/#{record_id}", config) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, {:connection_error, reason}}
    end
  end

  # --- Legacy API (UniFi Network 8.x+) ---

  defp legacy_api_base(config), do: "#{config.host}/proxy/network/v2/api/site/#{config.site}"

  defp legacy_api_list(config, zone_name) do
    case api_get("#{legacy_api_base(config)}/static-dns", config) do
      {:ok, %Req.Response{status: 200, body: records}} when is_list(records) ->
        filtered =
          records
          |> Enum.filter(&record_in_zone?(&1, zone_name))
          |> Enum.map(&normalize_legacy_record/1)

        {:ok, filtered}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp legacy_api_create(config, zone_name, record) do
    fqdn = build_fqdn(record, zone_name)

    body = %{
      "record_type" => record[:type] || record["type"],
      "key" => fqdn,
      "value" => record[:value] || record["value"]
    }

    case api_post("#{legacy_api_base(config)}/static-dns", body, config) do
      {:ok, %Req.Response{status: status, body: result}} when status in [200, 201] ->
        {:ok, normalize_legacy_record(result)}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:api_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp legacy_api_update(config, zone_name, record_id, record) do
    with :ok <- legacy_api_delete(config, zone_name, record_id) do
      legacy_api_create(config, zone_name, record)
    end
  end

  defp legacy_api_delete(config, _zone_name, record_id) do
    case api_delete("#{legacy_api_base(config)}/static-dns/#{record_id}", config) do
      {:ok, %Req.Response{status: status}} when status in [200, 204] -> :ok
      {:ok, %Req.Response{status: status, body: body}} -> {:error, {:api_error, status, body}}
      {:error, reason} -> {:error, {:connection_error, reason}}
    end
  end

  # --- API version detection ---

  defp detect_api_version(config) do
    case config.api_version do
      "new" ->
        {:new, %{config | api_version: "new"}}

      "legacy" ->
        {:legacy, %{config | api_version: "legacy"}}

      _ ->
        case api_get("#{new_api_base(config)}/dns/policies", config) do
          {:ok, %Req.Response{status: 200}} -> {:new, %{config | api_version: "new"}}
          _ -> {:legacy, %{config | api_version: "legacy"}}
        end
    end
  end

  # --- HTTP helpers ---

  defp api_get(url, config) do
    Req.get(url, headers: auth_headers(config), connect_options: connect_opts(config))
  end

  defp api_post(url, body, config) do
    Req.post(url,
      headers: auth_headers(config),
      json: body,
      connect_options: connect_opts(config)
    )
  end

  defp api_put(url, body, config) do
    Req.put(url,
      headers: auth_headers(config),
      json: body,
      connect_options: connect_opts(config)
    )
  end

  defp api_delete(url, config) do
    Req.delete(url, headers: auth_headers(config), connect_options: connect_opts(config))
  end

  defp auth_headers(config) do
    [{"x-api-key", config.api_key}]
  end

  defp connect_opts(config) do
    if config.skip_tls_verify do
      [transport_opts: [verify: :verify_none]]
    else
      []
    end
  end

  # --- Record normalization ---

  defp normalize_new_api_record(r) do
    %{
      id: r["_id"] || r["id"],
      name: r["key"],
      type: r["record_type"],
      value: r["value"],
      ttl: r["ttl"] || 300
    }
  end

  defp normalize_legacy_record(r) do
    %{
      id: r["_id"] || r["id"],
      name: r["key"],
      type: r["record_type"],
      value: r["value"],
      ttl: 300
    }
  end

  # --- Helpers ---

  defp record_in_zone?(record, zone_name) do
    key = record["key"] || record["name"] || ""
    String.ends_with?(key, ".#{zone_name}") or key == zone_name
  end

  defp build_fqdn(record, zone_name) do
    name = record[:name] || record["name"]

    if String.ends_with?(name, ".#{zone_name}") or name == zone_name do
      name
    else
      "#{name}.#{zone_name}"
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp require_config do
    host = Homelab.Settings.get("unifi_host")
    api_key = Homelab.Settings.get("unifi_api_key")

    case {host, api_key} do
      {nil, _} ->
        {:error, :not_configured}

      {_, nil} ->
        {:error, :not_configured}

      _ ->
        {:ok,
         %{
           host: String.trim_trailing(host, "/"),
           api_key: api_key,
           site: Homelab.Settings.get("unifi_site") || "default",
           api_version: Homelab.Settings.get("unifi_api_version") || "auto",
           skip_tls_verify: Homelab.Settings.get("unifi_skip_tls_verify") == "true"
         }}
    end
  end
end
