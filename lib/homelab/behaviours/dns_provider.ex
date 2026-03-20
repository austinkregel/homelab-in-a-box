defmodule Homelab.Behaviours.DnsProvider do
  @moduledoc """
  Behaviour for DNS record management.

  Implementations manage DNS records for providers like Cloudflare,
  UniFi Network, Pi-hole, etc. Providers may be scoped to public
  (external) or internal (LAN) DNS resolution.
  """

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @doc "The scope this provider operates in: :public, :internal, or :both"
  @callback scope() :: :public | :internal | :both

  @callback list_records(zone_id :: String.t()) :: {:ok, [map()]} | {:error, term()}

  @callback create_record(zone_id :: String.t(), record :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback update_record(zone_id :: String.t(), record_id :: String.t(), record :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback delete_record(zone_id :: String.t(), record_id :: String.t()) ::
              :ok | {:error, term()}
end
