defmodule HomelabWeb.Plugs.RequireAuthApi do
  @moduledoc """
  Authentication for the JSON API. Accepts two credentials: the browser's session cookie,
  and an OAuth2 `client_credentials` bearer token identifying a machine.

  Same question as `HomelabWeb.Plugs.RequireAuth` — who is this? — with two deliberate
  differences from the browser plug.

  **It refuses with 401, not a redirect.** A 302 to the OIDC login page is not an answer
  a JSON client can act on: `curl` follows it and reports a 200 containing HTML, so a
  script cannot tell "denied" from "worked".

  **It does not fail open before setup completes.** `RequireAuth` lets everything through
  while `setup_completed?/0` is false, because the setup wizard has to be reachable before
  there is anyone to log in as. The API has no such need, and an unconfigured box is
  exactly when nobody is watching it — so the exemption stops at the browser.

  This exists because the API scope previously had no authentication at all. Every route
  under it was public on `https://<base_domain>/api/v1/...`, since the app's own Traefik
  rule matches `Host(base_domain)` with no path constraint. That included
  `POST /tenants/:id/deployments`, which reaches `deploy_now/1` — and `image_override`
  accepts any parseable reference, so it was unauthenticated arbitrary-image execution on
  the Docker host.

  A bearer token, once presented, decides the request — it never falls back to the session
  cookie, so a lapsed agent credential cannot borrow the operator's privileges. A machine
  resolves to a `:service` principal, which `admin?/1` is false for, so `RequireAdminApi`
  still refuses it every write. `:token_scopes` is a list for a machine, `nil` for a person.
  """
  import Plug.Conn

  require Logger

  alias Homelab.Auth.MachineToken
  alias HomelabWeb.Plugs.RequireAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case authenticate(conn) do
      {:ok, user, scopes} ->
        conn
        |> assign(:current_user, user)
        |> assign(:token_scopes, scopes)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
        |> halt()
    end
  end

  defp authenticate(conn) do
    case bearer_token(conn) do
      nil -> session_user(conn)
      token -> machine_principal(token)
    end
  end

  defp session_user(conn) do
    case RequireAuth.current_user(conn) do
      {:ok, user} -> {:ok, user, nil}
      :error -> :error
    end
  end

  # One 401 for every failure; the reason is logged, not returned.
  defp machine_principal(token) do
    case MachineToken.authenticate(token) do
      {:ok, user, scopes} ->
        {:ok, user, scopes}

      {:error, reason} ->
        Logger.info("Machine token refused: #{inspect(reason)}")
        :error
    end
  end

  # RFC 6750: the scheme is case-insensitive.
  defp bearer_token(conn) do
    with [header | _] <- get_req_header(conn, "authorization"),
         [scheme, token] <- String.split(header, " ", parts: 2),
         true <- String.downcase(scheme) == "bearer",
         token = String.trim(token),
         false <- token == "" do
      token
    else
      _ -> nil
    end
  end
end
