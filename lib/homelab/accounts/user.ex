defmodule Homelab.Accounts.User do
  @moduledoc """
  User schema for OIDC-authenticated users.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :sub, :string
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :role, Ecto.Enum, values: [:admin, :member], default: :member
    field :last_login_at, :utc_datetime

    timestamps()
  end

  @doc false
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:sub, :email, :name, :avatar_url, :role])
    |> validate_required([:sub, :email])
    |> unique_constraint(:sub)
    |> unique_constraint(:email)
    |> validate_inclusion(:role, [:admin, :member])
  end
end
