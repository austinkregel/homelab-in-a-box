defmodule Homelab.IdentityBrokers.GenericOidc do
  @moduledoc """
  Generic OIDC identity broker implementation.

  Works with any standards-compliant OIDC provider by using the provider's
  API to manage client registrations and user assignments. Supports
  Authentik, Keycloak, aut.hair, and other OIDC-compliant servers.

  Configuration:
    config :homelab, Homelab.IdentityBrokers.GenericOidc,
      base_url: "https://auth.example.com",
      api_token: "your-api-token",
      admin_group: "homelab-admins"
  """

  @behaviour Homelab.Behaviours.IdentityBroker

  @impl true
  def driver_id, do: "generic_oidc"

  @impl true
  def display_name, do: "Generic OIDC"

  @impl true
  def description, do: "Standards-compliant OIDC provider (Authentik, Keycloak, aut.hair, etc.)"

  @impl true
  def create_client(app_name, redirect_uris) do
    config = config()
    base_url = Keyword.fetch!(config, :base_url)
    token = Keyword.fetch!(config, :api_token)

    body = %{
      "client_id" => "homelab_#{sanitize(app_name)}",
      "client_type" => "confidential",
      "redirect_uris" => Enum.join(redirect_uris, "\n"),
      "authorization_grant_type" => "authorization-code",
      "name" => "Homelab: #{app_name}"
    }

    case http_post("#{base_url}/api/v3/providers/oauth2/", body, token) do
      {:ok, %{"client_id" => client_id, "client_secret" => client_secret}} ->
        {:ok,
         %{
           client_id: client_id,
           client_secret: client_secret,
           redirect_uri: List.first(redirect_uris)
         }}

      {:ok, response} ->
        # Some providers return differently structured responses
        {:ok,
         %{
           client_id: response["client_id"] || "homelab_#{sanitize(app_name)}",
           client_secret: response["client_secret"] || response["secret"],
           redirect_uri: List.first(redirect_uris)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def delete_client(client_id) do
    config = config()
    base_url = Keyword.fetch!(config, :base_url)
    token = Keyword.fetch!(config, :api_token)

    case http_delete("#{base_url}/api/v3/providers/oauth2/?client_id=#{client_id}", token) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_clients do
    config = config()
    base_url = Keyword.fetch!(config, :base_url)
    token = Keyword.fetch!(config, :api_token)

    case http_get("#{base_url}/api/v3/providers/oauth2/", token) do
      {:ok, %{"results" => results}} ->
        clients =
          Enum.map(results, fn r ->
            %{
              client_id: r["client_id"],
              client_secret: r["client_secret"],
              redirect_uri: r["redirect_uris"]
            }
          end)

        {:ok, clients}

      {:ok, results} when is_list(results) ->
        clients =
          Enum.map(results, fn r ->
            %{
              client_id: r["client_id"],
              client_secret: r["client_secret"],
              redirect_uri: r["redirect_uris"]
            }
          end)

        {:ok, clients}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def create_user(email, attrs) do
    config = config()
    base_url = Keyword.fetch!(config, :base_url)
    token = Keyword.fetch!(config, :api_token)

    body = %{
      "email" => email,
      "username" => attrs[:username] || email_to_username(email),
      "name" => attrs[:name] || email,
      "is_active" => true
    }

    case http_post("#{base_url}/api/v3/core/users/", body, token) do
      {:ok, user} -> {:ok, user}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def assign_user_to_group(user_id, group) do
    config = config()
    base_url = Keyword.fetch!(config, :base_url)
    token = Keyword.fetch!(config, :api_token)

    body = %{"pk" => user_id}

    case http_post("#{base_url}/api/v3/core/groups/#{group}/add_user/", body, token) do
      {:ok, _} -> :ok
      :ok -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # --- HTTP helpers ---

  defp http_get(url, token) do
    Req.get(url,
      headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}],
      retry: false
    )
    |> handle_response()
  end

  defp http_post(url, body, token) do
    Req.post(url,
      json: body,
      headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}],
      retry: false
    )
    |> handle_response()
  end

  defp http_delete(url, token) do
    Req.delete(url,
      headers: [{"authorization", "Bearer #{token}"}, {"accept", "application/json"}],
      retry: false
    )
    |> handle_response()
  end

  defp handle_response({:ok, %Req.Response{status: 204}}) do
    :ok
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}})
       when status in 200..299 do
    {:ok, body}
  end

  defp handle_response({:ok, %Req.Response{status: 404}}) do
    {:error, :not_found}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}) do
    {:error, {:http_error, status, body}}
  end

  defp handle_response({:error, reason}) do
    {:error, {:connection_error, reason}}
  end

  defp config do
    Application.get_env(:homelab, __MODULE__, [])
  end

  defp sanitize(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_-]/, "_")
  end

  defp email_to_username(email) do
    email |> String.split("@") |> List.first()
  end
end
