defmodule HomelabWeb.Plugs.RequireAuthApi do
  @moduledoc """
  Session authentication for the JSON API.

  Same question as `HomelabWeb.Plugs.RequireAuth` — is there a logged-in user? — with
  two deliberate differences.

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
  """
  import Plug.Conn

  alias HomelabWeb.Plugs.RequireAuth

  def init(opts), do: opts

  def call(conn, _opts) do
    case RequireAuth.current_user(conn) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :error ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(401, Jason.encode!(%{errors: %{detail: "Unauthorized"}}))
        |> halt()
    end
  end
end
