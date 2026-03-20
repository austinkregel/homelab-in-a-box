defmodule Homelab.Notifications do
  @moduledoc """
  Context for user notifications.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Notifications.Notification

  @doc """
  Creates a notification and broadcasts it via PubSub on topic "notifications:{user_id}".
  """
  def create(attrs) do
    case %Notification{}
         |> Notification.changeset(attrs)
         |> Repo.insert() do
      {:ok, notification} = result ->
        if notification.user_id do
          Phoenix.PubSub.broadcast(
            Homelab.PubSub,
            "notifications:#{notification.user_id}",
            {:notification, notification}
          )
        end

        result

      error ->
        error
    end
  end

  @doc """
  Returns unread notifications for a user.
  """
  def list_unread(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
    |> order_by([n], desc: n.inserted_at)
    |> Repo.all()
  end

  @doc """
  Returns recent notifications for a user. Default limit is 20.
  """
  def list_recent(user_id, limit \\ 20) do
    Notification
    |> where(user_id: ^user_id)
    |> order_by([n], desc: n.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc """
  Marks a notification as read.
  """
  def mark_read(%Notification{} = notification) do
    notification
    |> Notification.changeset(%{read_at: DateTime.utc_now()})
    |> Repo.update()
  end

  @doc """
  Marks all notifications as read for a user.
  """
  def mark_all_read(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
    |> Repo.update_all(set: [read_at: DateTime.utc_now()])
  end

  @doc """
  Returns the count of unread notifications for a user.
  """
  def unread_count(user_id) do
    Notification
    |> where([n], n.user_id == ^user_id and is_nil(n.read_at))
    |> Repo.aggregate(:count, :id)
  end
end
