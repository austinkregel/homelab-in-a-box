defmodule Homelab.Behaviours.IdentityBroker do
  @moduledoc """
  Behaviour for OIDC identity brokers.

  Implementations manage OIDC client registrations and user/group
  assignments for any compliant OIDC provider (Authentik, Keycloak,
  aut.hair, etc.).
  """

  @type client_config :: %{
          client_id: String.t(),
          client_secret: String.t(),
          redirect_uri: String.t()
        }

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback create_client(app_name :: String.t(), redirect_uris :: [String.t()]) ::
              {:ok, client_config()} | {:error, term()}
  @callback delete_client(client_id :: String.t()) :: :ok | {:error, term()}
  @callback list_clients() :: {:ok, [client_config()]} | {:error, term()}
  @callback create_user(email :: String.t(), attrs :: map()) :: {:ok, map()} | {:error, term()}
  @callback assign_user_to_group(user_id :: String.t(), group :: String.t()) ::
              :ok | {:error, term()}
end
