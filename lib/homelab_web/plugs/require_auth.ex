defmodule HomelabWeb.Plugs.RequireAuth do
  @moduledoc """
  Ensures the user is authenticated. Assigns :current_user when present.

  If Homelab.Settings.setup_completed?/0 returns false, the request
  is allowed through so the setup wizard can work without auth.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Homelab.Accounts
  alias Homelab.Settings

  def init(opts), do: opts

  def call(conn, _opts) do
    if Settings.setup_completed?() do
      require_auth(conn)
    else
      conn
    end
  end

  defp require_auth(conn) do
    case get_session(conn, :user_id) do
      nil ->
        conn
        |> redirect(to: "/auth/oidc")
        |> halt()

      user_id ->
        case Accounts.get_user(user_id) do
          nil ->
            conn
            |> delete_session(:user_id)
            |> redirect(to: "/auth/oidc")
            |> halt()

          user ->
            assign(conn, :current_user, user)
        end
    end
  end
end
