defmodule Homelab.Audit.ActivityLog do
  @moduledoc """
  Schema for activity/audit log entries.
  """

  use Ecto.Schema
  import Ecto.Changeset

  schema "activity_logs" do
    field :action, :string
    field :resource_type, :string
    field :resource_id, :integer
    field :metadata, :map, default: %{}

    belongs_to :user, Homelab.Accounts.User

    field :inserted_at, :utc_datetime_usec
  end

  @doc false
  def changeset(activity_log, attrs) do
    activity_log
    |> cast(attrs, [:user_id, :action, :resource_type, :resource_id, :metadata, :inserted_at])
    |> validate_required([:action, :resource_type, :inserted_at])
    |> foreign_key_constraint(:user_id)
  end
end
