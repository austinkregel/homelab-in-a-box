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

  @doc """
  Resolves the session's user, or `:error`.

  Public so the API plug can answer "who is this" the same way rather than growing a
  second, drifting definition — the two differ only in how they REFUSE (a redirect to
  the login page vs. a 401), not in who they let through.
  """
  @spec current_user(Plug.Conn.t()) :: {:ok, Homelab.Accounts.User.t()} | :error
  def current_user(conn) do
    with user_id when not is_nil(user_id) <- get_session(conn, :user_id),
         %{} = user <- Accounts.get_user(user_id) do
      {:ok, user}
    else
      _ -> :error
    end
  end

  defp require_auth(conn) do
    case current_user(conn) do
      {:ok, user} ->
        assign(conn, :current_user, user)

      :error ->
        conn
        |> delete_session(:user_id)
        |> redirect(to: "/auth/oidc")
        |> halt()
    end
  end
end
