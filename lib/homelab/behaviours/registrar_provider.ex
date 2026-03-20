defmodule Homelab.Behaviours.RegistrarProvider do
  @moduledoc """
  Behaviour for domain registrar integration.

  Implementations sync the list of domains owned at a registrar.
  DNS record management is handled separately by `Homelab.Behaviours.DnsProvider`.
  """

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback list_domains() :: {:ok, [map()]} | {:error, term()}

  @callback get_nameservers(domain :: String.t()) :: {:ok, [String.t()]} | {:error, term()}
end
