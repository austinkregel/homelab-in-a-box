defmodule Homelab.NotificationsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Notifications
  import Homelab.Factory

  describe "create/1" do
    test "creates a notification" do
      user = insert(:user)

      assert {:ok, notification} =
               Notifications.create(%{
                 user_id: user.id,
                 title: "Deploy complete",
                 body: "Your app is live",
                 severity: "success"
               })

      assert notification.title == "Deploy complete"
      assert notification.severity == "success"
    end

    test "broadcasts via PubSub when user_id is set" do
      user = insert(:user)
      Phoenix.PubSub.subscribe(Homelab.PubSub, "notifications:#{user.id}")

      {:ok, notification} =
        Notifications.create(%{
          user_id: user.id,
          title: "Test notification",
          severity: "info"
        })

      assert_receive {:notification, ^notification}
    end

    test "validates required fields" do
      assert {:error, changeset} = Notifications.create(%{})
      assert errors_on(changeset)[:title] != nil
    end

    test "validates severity inclusion" do
      assert {:error, changeset} =
               Notifications.create(%{title: "Bad", severity: "critical"})

      assert errors_on(changeset)[:severity] != nil
    end
  end

  describe "list_unread/1" do
    test "returns only unread notifications for the user" do
      user = insert(:user)

      {:ok, _} = Notifications.create(%{user_id: user.id, title: "Unread", severity: "info"})

      {:ok, read} =
        Notifications.create(%{user_id: user.id, title: "Read", severity: "info"})

      Notifications.mark_read(read)

      unread = Notifications.list_unread(user.id)
      assert length(unread) == 1
      assert hd(unread).title == "Unread"
    end
  end

  describe "list_recent/2" do
    test "returns notifications for a user with limit" do
      user = insert(:user)
      for i <- 1..5, do: Notifications.create(%{user_id: user.id, title: "N#{i}", severity: "info"})

      assert length(Notifications.list_recent(user.id, 3)) == 3
    end
  end

  describe "mark_read/1" do
    test "sets read_at on the notification" do
      user = insert(:user)
      {:ok, notification} = Notifications.create(%{user_id: user.id, title: "To read", severity: "info"})
      assert notification.read_at == nil

      {:ok, updated} = Notifications.mark_read(notification)
      assert updated.read_at != nil
    end
  end

  describe "mark_all_read/1" do
    test "marks all notifications as read for a user" do
      user = insert(:user)
      for _ <- 1..3, do: Notifications.create(%{user_id: user.id, title: "Unread", severity: "info"})

      assert Notifications.unread_count(user.id) == 3
      Notifications.mark_all_read(user.id)
      assert Notifications.unread_count(user.id) == 0
    end
  end

  describe "unread_count/1" do
    test "returns count of unread notifications" do
      user = insert(:user)
      assert Notifications.unread_count(user.id) == 0

      {:ok, _} = Notifications.create(%{user_id: user.id, title: "One", severity: "info"})
      assert Notifications.unread_count(user.id) == 1
    end
  end
end
