defmodule HomelabWeb.Plugs.RequireAdminApi do
  @moduledoc """
  Restricts a JSON API route to `:admin` users. Runs after
  `HomelabWeb.Plugs.RequireAuthApi`, which is what puts `:current_user` on the conn.

  Same question as `HomelabWeb.Plugs.RequireAdmin` — `Homelab.Accounts.admin?/1`, one
  predicate for every layer — and it exists for the same reason `RequireAuthApi` exists
  alongside `RequireAuth`: **a redirect is not an answer a JSON client can act on.**
  `RequireAdmin` answers 302 to `/`, which `curl` follows and reports as a 200 full of
  HTML, so a script cannot tell "refused" from "worked".

  403, not 401. The caller proved who they are; the API is refusing what they asked for,
  not who they are, and a 401 would invite a client to go and re-authenticate as though
  that would help.

  Covers the mutating half of `/api/v1`: creating, updating and deleting tenants and
  deployments, scheduling backups, and restoring snapshots. Reads stay open to members —
  `POST /tenants/:id/deployments` reaches `deploy_now/1` and `image_override` takes any
  parseable reference, so writes are arbitrary-image execution on the Docker host and
  belong to administrators; listing what is deployed does not.
  """
  import Plug.Conn

  alias Homelab.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if Accounts.admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(403, Jason.encode!(%{errors: %{detail: "Forbidden"}}))
      |> halt()
    end
  end
end
