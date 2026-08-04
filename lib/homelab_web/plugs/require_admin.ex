defmodule HomelabWeb.Plugs.RequireAdmin do
  @moduledoc """
  Restricts a browser route to `:admin` users. Runs after `HomelabWeb.Plugs.RequireAuth`,
  which is what puts `:current_user` on the conn.

  `users.role` has always existed; nothing enforced it, so every authenticated user was
  an administrator. This is the enforcement, and like `RequireAuth` it only decides how
  to REFUSE — `Homelab.Accounts.admin?/1` is the predicate, shared with the LiveView
  `on_mount(:require_admin)` hook so the two layers cannot drift.

  ## No admins means nobody is an admin

  There is deliberately no exemption for an instance that holds no administrator. An
  earlier draft let everyone through in that state, reasoning that a strict gate would
  lock an upgrading instance out of the only page that can appoint one. That premise was
  false: `Homelab.Accounts.get_or_create_breakglass_admin/1` inserts with `role: :admin`,
  so break-glass already IS the promotion path, and it is the documented way back in when
  the identity provider is unreachable.

  An exemption keyed on "no admins exist" is also reachable rather than hypothetical —
  demote your way down to zero and every signed-in user becomes an administrator. That is
  exactly what `Accounts.update_user/2`'s last-admin guard exists to prevent, re-entered
  through the other door. "No admins, so nobody is admin, use break-glass" is simpler and
  strictly safer.

  ## Refusal

  A redirect to `/` with a flash, not a 403 page: these are browser routes reached from
  the sidebar, and the user is legitimately signed in — they are just not allowed here.
  Sending them somewhere they can use beats a dead end. The JSON API has its own plug,
  `HomelabWeb.Plugs.RequireAdminApi`, because a redirect is not an answer a JSON client
  can act on.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Homelab.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if Accounts.admin?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> put_flash(:error, "That area is restricted to administrators.")
      |> redirect(to: "/")
      |> halt()
    end
  end
end
