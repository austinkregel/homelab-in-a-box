defmodule HomelabWeb.Plugs.RequireSetup do
  @moduledoc """
  Redirects to /setup when setup is not completed, unless the request
  is already for /setup or an auth path.

  If setup IS completed and the path is /setup, redirects to /.
  """
  import Plug.Conn
  import Phoenix.Controller

  alias Homelab.Settings

  def init(opts), do: opts

  def call(conn, _opts) do
    path = conn.request_path

    cond do
      not Settings.setup_completed?() and not setup_path?(path) and not auth_path?(path) ->
        conn
        |> redirect(to: "/setup")
        |> halt()

      Settings.setup_completed?() and setup_path?(path) ->
        conn
        |> redirect(to: "/")
        |> halt()

      true ->
        conn
    end
  end

  defp setup_path?("/setup"), do: true
  defp setup_path?("/setup" <> _), do: true
  defp setup_path?(_), do: false

  defp auth_path?(path), do: String.starts_with?(path, "/auth")
end
