defmodule HomelabWeb.AuthController do
  use HomelabWeb, :controller

  require Logger

  alias Homelab.Accounts
  alias Homelab.Auth.OidcDiscovery
  alias Homelab.Settings

  def login(conn, _params) do
    issuer = Settings.get("oidc_issuer")
    client_id = Settings.get("oidc_client_id")

    if is_nil(issuer) or is_nil(client_id) do
      conn
      |> put_flash(:error, "OIDC is not configured. Please complete setup.")
      |> redirect(to: "/setup")
    else
      case OidcDiscovery.discover(issuer) do
        {:ok, discovery} ->
          state = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
          redirect_uri = Phoenix.VerifiedRoutes.unverified_url(conn, "/auth/oidc/callback")

          conn
          |> put_session(:oidc_state, state)
          |> redirect(
            external: build_authorization_url(discovery, client_id, redirect_uri, state)
          )

        {:error, _reason} ->
          conn
          |> put_flash(:error, "Failed to discover OIDC provider.")
          |> redirect(to: "/")
      end
    end
  end

  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :oidc_state)

    if session_state != state or is_nil(session_state) do
      conn
      |> put_flash(:error, "Invalid state. Please try again.")
      |> redirect(to: "/")
    else
      issuer = Settings.get("oidc_issuer")
      client_id = Settings.get("oidc_client_id")
      client_secret = Settings.get("oidc_client_secret")
      redirect_uri = Phoenix.VerifiedRoutes.unverified_url(conn, "/auth/oidc/callback")

      case OidcDiscovery.discover(issuer) do
        {:ok, discovery} ->
          case exchange_code_for_tokens(
                 discovery.token_endpoint,
                 code,
                 client_id,
                 client_secret,
                 redirect_uri
               ) do
            {:ok, %{"access_token" => access_token}} ->
              case fetch_userinfo(discovery.userinfo_endpoint, access_token) do
                {:ok, userinfo} ->
                  case Accounts.get_or_create_from_oidc(userinfo) do
                    {:ok, user} ->
                      Accounts.update_last_login(user)

                      conn
                      |> delete_session(:oidc_state)
                      |> put_session(:user_id, user.id)
                      |> put_flash(:info, "Signed in successfully.")
                      |> redirect(to: "/")

                    {:error, _changeset} ->
                      conn
                      |> put_flash(:error, "Failed to create or update user.")
                      |> redirect(to: "/")
                  end

                {:error, reason} ->
                  Logger.error("OIDC userinfo fetch failed: #{inspect(reason)}")

                  conn
                  |> put_flash(:error, "Failed to fetch user info.")
                  |> redirect(to: "/")
              end

            {:error, reason} ->
              Logger.error(
                "OIDC token exchange failed: #{inspect(reason)}, redirect_uri=#{redirect_uri}"
              )

              detail = token_error_detail(reason)

              conn
              |> put_flash(:error, "Failed to exchange code for tokens: #{detail}")
              |> redirect(to: "/")
          end

        {:error, reason} ->
          Logger.error("OIDC discovery failed for #{issuer}: #{inspect(reason)}")

          conn
          |> put_flash(:error, "Failed to discover OIDC provider.")
          |> redirect(to: "/")
      end
    end
  end

  def callback(conn, _params) do
    conn
    |> put_flash(:error, "Missing code or state from OIDC provider.")
    |> redirect(to: "/")
  end

  def logout(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> put_flash(:info, "Signed out successfully.")
    |> redirect(to: "/")
  end

  defp build_authorization_url(discovery, client_id, redirect_uri, state) do
    params =
      URI.encode_query(%{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => redirect_uri,
        "scope" => "openid email profile",
        "state" => state
      })

    discovery.authorization_endpoint <> "?" <> params
  end

  defp exchange_code_for_tokens(token_endpoint, code, client_id, client_secret, redirect_uri) do
    body = [
      grant_type: "authorization_code",
      code: code,
      redirect_uri: redirect_uri,
      client_id: client_id,
      client_secret: client_secret || ""
    ]

    Logger.debug(
      "OIDC token exchange: endpoint=#{token_endpoint} redirect_uri=#{redirect_uri} client_id=#{client_id} secret_present?=#{client_secret not in [nil, ""]}"
    )

    case Req.post(token_endpoint, form: body, receive_timeout: 10_000) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status, body: body}} ->
        Logger.error("OIDC token endpoint returned #{status}: #{inspect(body)}")
        {:error, {:token_error, status, body}}

      {:error, reason} ->
        Logger.error("OIDC token endpoint connection error: #{inspect(reason)}")
        {:error, {:connection_error, reason}}
    end
  end

  defp token_error_detail({:token_error, status, %{"error" => error} = body}) do
    desc = Map.get(body, "error_description", "")
    if desc != "", do: "#{error} - #{desc} (HTTP #{status})", else: "#{error} (HTTP #{status})"
  end

  defp token_error_detail({:token_error, status, body}) when is_binary(body) do
    "HTTP #{status}: #{String.slice(body, 0, 200)}"
  end

  defp token_error_detail({:token_error, status, _body}), do: "HTTP #{status}"
  defp token_error_detail({:connection_error, reason}), do: "connection error: #{inspect(reason)}"
  defp token_error_detail(other), do: inspect(other)

  defp fetch_userinfo(userinfo_endpoint, access_token) do
    case Req.get(userinfo_endpoint,
           headers: [{"authorization", "Bearer #{access_token}"}],
           receive_timeout: 10_000
         ) do
      {:ok, %Req.Response{status: 200, body: body}} when is_map(body) ->
        {:ok, body}

      {:ok, %Req.Response{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end
end
