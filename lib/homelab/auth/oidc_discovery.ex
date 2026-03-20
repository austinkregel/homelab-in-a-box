defmodule Homelab.Auth.OidcDiscovery do
  @moduledoc """
  Fetches and parses OIDC provider capabilities from the
  `.well-known/openid-configuration` endpoint.
  """

  defstruct [
    :issuer,
    :authorization_endpoint,
    :token_endpoint,
    :userinfo_endpoint,
    :jwks_uri,
    :device_authorization_endpoint,
    :end_session_endpoint,
    grant_types_supported: [],
    scopes_supported: [],
    response_types_supported: [],
    token_endpoint_auth_methods_supported: [],
    raw: %{}
  ]

  @type t :: %__MODULE__{}

  @doc """
  Fetches the OIDC discovery document from the given issuer URL.
  """
  @spec discover(String.t()) :: {:ok, t()} | {:error, term()}
  def discover(issuer_url) do
    url =
      issuer_url
      |> String.trim_trailing("/")
      |> Kernel.<>("/.well-known/openid-configuration")

    case Req.get(url, retry: false, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, parse(body)}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @doc """
  Checks whether the discovery document advertises the given grant type.
  """
  def supports_grant?(%__MODULE__{grant_types_supported: grants}, grant_type) do
    grant_type in grants
  end

  def supports_authorization_code?(discovery) do
    supports_grant?(discovery, "authorization_code")
  end

  def supports_device_flow?(discovery) do
    supports_grant?(discovery, "urn:ietf:params:oauth:grant-type:device_code") ||
      discovery.device_authorization_endpoint != nil
  end

  def supports_refresh?(discovery) do
    supports_grant?(discovery, "refresh_token")
  end

  @doc """
  Serializes a discovery struct to a JSON-encodable map for storage.
  """
  def to_json(%__MODULE__{} = d) do
    Jason.encode!(Map.from_struct(d) |> Map.delete(:raw))
  end

  @doc """
  Deserializes a stored JSON string back into a discovery struct.
  """
  def from_json(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, map} -> {:ok, parse(map)}
      error -> error
    end
  end

  defp parse(body) do
    %__MODULE__{
      issuer: body["issuer"],
      authorization_endpoint: body["authorization_endpoint"],
      token_endpoint: body["token_endpoint"],
      userinfo_endpoint: body["userinfo_endpoint"],
      jwks_uri: body["jwks_uri"],
      device_authorization_endpoint: body["device_authorization_endpoint"],
      end_session_endpoint: body["end_session_endpoint"],
      grant_types_supported: body["grant_types_supported"] || [],
      scopes_supported: body["scopes_supported"] || [],
      response_types_supported: body["response_types_supported"] || [],
      token_endpoint_auth_methods_supported: body["token_endpoint_auth_methods_supported"] || [],
      raw: body
    }
  end
end
