defmodule HomelabWeb.Plugs.RequireAdmin do
  @moduledoc """
  Restricts a route to `:admin` users. Runs after `HomelabWeb.Plugs.RequireAuth`, which
  is what puts `:current_user` on the conn.

  `users.role` has always existed; nothing enforced it, so every authenticated user was
  an administrator. This is the enforcement, and like `RequireAuth` it only decides how
  to REFUSE — `Homelab.Accounts.admin?/1` is the predicate, shared with the LiveView
  `on_mount(:require_admin)` hook so the two layers cannot drift.

  ## The bootstrap exemption

  If the instance has no administrator at all, this lets the request through and logs a
  warning. `role` defaults to `:member` and, before enforcement existed, nothing set
  `:admin` except a break-glass login — so an instance upgrading into this change can
  genuinely hold zero admins, and a strict gate would lock everyone out of the only page
  that can promote someone. It is the same bargain `RequireAuth` makes while setup is
  incomplete: fail open only while there is nobody who could possibly say yes. The
  exemption closes permanently the moment one admin exists, and new instances never
  enter it because the first OIDC user provisions as `:admin`.

  ## Refusal

  A redirect to `/` with a flash, not a 403 page: these are browser routes reached from
  the sidebar, and the user is legitimately signed in — they are just not allowed here.
  Sending them somewhere they can use beats a dead end. The JSON API is not wired to
  this plug; it has no admin-only routes today.
  """
  import Plug.Conn
  import Phoenix.Controller

  require Logger

  alias Homelab.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    if authorized?(conn.assigns[:current_user]) do
      conn
    else
      conn
      |> put_flash(:error, "That area is restricted to administrators.")
      |> redirect(to: "/")
      |> halt()
    end
  end

  @doc """
  Whether this user may reach an admin-only route, bootstrap exemption included.

  Public so the `on_mount(:require_admin)` hook asks the identical question — the two
  differ only in how they refuse (a redirect vs. a halted mount).
  """
  @spec authorized?(Homelab.Accounts.User.t() | nil) :: boolean()
  def authorized?(user) do
    cond do
      Accounts.admin?(user) ->
        true

      is_nil(user) ->
        # Nobody is signed in. RequireAuth should already have refused; if the route was
        # wired without it, do not let the bootstrap exemption become an open door.
        false

      not Accounts.any_admin?() ->
        Logger.warning(
          "Admin route allowed for user_id=#{user.id} (#{user.email}): this instance has " <>
            "no administrator. Promote someone in Settings to close this exemption."
        )

        true

      true ->
        false
    end
  end
end
