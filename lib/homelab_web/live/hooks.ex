defmodule HomelabWeb.Live.Hooks do
  @moduledoc """
  LiveView on_mount hooks for setup and auth enforcement.
  """

  import Phoenix.LiveView
  import Phoenix.Component

  alias Homelab.Settings
  alias Homelab.Accounts
  alias Homelab.Notifications

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

  @doc """
  Wires the notification bell + dropdown into every authenticated LiveView without
  each one having to forward events: it seeds the count/list, subscribes to the
  per-user PubSub topic, and attaches hooks that intercept `{:notification, n}`
  messages and the `notif-*` events.
  """
  def on_mount(:notifications, _params, _session, socket) do
    case socket.assigns[:current_user] do
      nil ->
        {:cont, socket}

      user ->
        if connected?(socket) do
          Phoenix.PubSub.subscribe(Homelab.PubSub, "notifications:#{user.id}")
        end

        socket =
          socket
          |> assign_notifications(user.id)
          |> attach_hook(:notif_info, :handle_info, &notif_handle_info/2)
          |> attach_hook(:notif_events, :handle_event, &notif_handle_event/3)

        {:cont, socket}
    end
  end

  def on_mount(:redirect_if_setup_done, _params, _session, socket) do
    if Settings.setup_completed?() do
      {:halt, redirect(socket, to: "/")}
    else
      {:cont, socket}
    end
  end

  # --- Notification hook internals ---

  defp assign_notifications(socket, user_id) do
    socket
    |> assign(:notification_count, Notifications.unread_count(user_id))
    |> assign(:notifications, Notifications.list_recent(user_id, 10))
  end

  defp notif_handle_info({:notification, notification}, socket) do
    socket =
      socket
      |> update(:notifications, fn list -> [notification | list] |> Enum.take(10) end)
      |> update(:notification_count, &(&1 + 1))

    {:halt, socket}
  end

  defp notif_handle_info(_msg, socket), do: {:cont, socket}

  defp notif_handle_event("notif-open", %{"id" => id}, socket) do
    user = socket.assigns.current_user
    notification = Enum.find(socket.assigns.notifications, &(to_string(&1.id) == to_string(id)))
    if notification, do: Notifications.mark_read(notification)

    socket = assign_notifications(socket, user.id)

    # Older notifications predate link support; send those to the activity log
    # rather than leaving the click as a dead end.
    case notification && (notification.link || "/activity") do
      nil -> {:halt, socket}
      link -> {:halt, push_navigate(socket, to: link)}
    end
  end

  defp notif_handle_event("notif-mark-all-read", _params, socket) do
    user = socket.assigns.current_user
    Notifications.mark_all_read(user.id)
    {:halt, assign_notifications(socket, user.id)}
  end

  defp notif_handle_event(_event, _params, socket), do: {:cont, socket}
end
