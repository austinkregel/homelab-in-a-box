defmodule HomelabWeb.Live.Hooks do
  @moduledoc """
  LiveView on_mount hooks for setup and auth enforcement.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Homelab.Settings
  alias Homelab.Accounts

  def on_mount(:require_setup, _params, _session, socket) do
    if Settings.setup_completed?() do
      {:cont, socket}
    else
      {:halt, redirect(socket, to: "/setup")}
    end
  end

  def on_mount(:require_auth, _params, session, socket) do
    if Settings.setup_completed?() do
      case session["user_id"] || Map.get(session, :user_id) do
        nil ->
          {:halt, redirect(socket, to: "/auth/oidc")}

        user_id ->
          case Accounts.get_user(user_id) do
            nil -> {:halt, redirect(socket, to: "/auth/oidc")}
            user -> {:cont, assign(socket, :current_user, user)}
          end
      end
    else
      {:halt, redirect(socket, to: "/setup")}
    end
  end

  def on_mount(:redirect_if_setup_done, _params, _session, socket) do
    if Settings.setup_completed?() do
      {:halt, redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end
end
