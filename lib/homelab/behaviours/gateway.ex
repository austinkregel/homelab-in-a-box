defmodule Homelab.Behaviours.Gateway do
  @moduledoc """
  Behaviour for reverse proxy / gateway management.

  Implementations manage route registration, TLS certificate provisioning,
  and exposure mode enforcement for a gateway like Traefik, Caddy, etc.
  """

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback register_route(domain :: String.t(), upstream :: String.t(), opts :: keyword()) ::
              :ok | {:error, term()}
  @callback remove_route(domain :: String.t()) :: :ok | {:error, term()}
  @callback list_routes() :: {:ok, [map()]} | {:error, term()}
  @callback provision_tls(domain :: String.t()) :: {:ok, map()} | {:error, term()}
  @callback check_tls_expiry(domain :: String.t()) :: {:ok, DateTime.t()} | {:error, term()}
end
