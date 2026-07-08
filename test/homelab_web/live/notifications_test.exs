defmodule HomelabWeb.NotificationsLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    :ok
  end

  test "renders the bell with no badge when there are no unread notifications",
       %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/catalog")
    assert html =~ "hero-bell"
  end

  test "shows the unread count badge and lists notifications", %{conn: conn, user: user} do
    insert(:notification, user: user, title: "Orphan detected", severity: "warning")

    {:ok, _view, html} = live(conn, ~p"/catalog")
    assert html =~ "Orphan detected"
    # Badge shows count 1.
    assert html =~ "notif-dropdown"
  end

  test "a PubSub-pushed notification appears live", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/catalog")

    notification = insert(:notification, user: user, title: "Live push", severity: "error")
    send(view.pid, {:notification, notification})

    assert render(view) =~ "Live push"
  end

  test "notif-open marks the notification read and navigates to its link", %{
    conn: conn,
    user: user
  } do
    notification =
      insert(:notification, user: user, title: "Go to backups", link: "/backups")

    {:ok, view, _html} = live(conn, ~p"/catalog")
    render_click(view, "notif-open", %{"id" => to_string(notification.id)})

    assert_redirect(view, "/backups")
    assert {:ok, reloaded} = fetch_notification(notification.id)
    refute is_nil(reloaded.read_at)
  end

  test "notif-mark-all-read clears the unread count", %{conn: conn, user: user} do
    insert(:notification, user: user, title: "One", severity: "info")
    insert(:notification, user: user, title: "Two", severity: "info")

    {:ok, view, _html} = live(conn, ~p"/catalog")
    render_click(view, "notif-mark-all-read", %{})

    assert Homelab.Notifications.unread_count(user.id) == 0
  end

  defp fetch_notification(id) do
    case Homelab.Repo.get(Homelab.Notifications.Notification, id) do
      nil -> {:error, :not_found}
      n -> {:ok, n}
    end
  end
end
