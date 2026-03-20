defmodule Homelab.Notifications.Notification do
  @moduledoc """
  Schema for user notifications.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "notifications" do
    field :title, :string
    field :body, :string
    field :severity, :string, default: "info"
    field :read_at, :utc_datetime
    field :link, :string

    belongs_to :user, Homelab.Accounts.User

    timestamps()
  end

  @doc false
  def changeset(notification, attrs) do
    notification
    |> cast(attrs, [:user_id, :title, :body, :severity, :read_at, :link])
    |> validate_required([:title, :severity])
    |> validate_inclusion(:severity, ["info", "warning", "error", "success"])
    |> foreign_key_constraint(:user_id)
  end
end
