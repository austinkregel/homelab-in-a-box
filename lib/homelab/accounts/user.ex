defmodule Homelab.Accounts.User do
  @moduledoc """
  A principal this instance has seen: a person, or a machine.

  `:admin` and `:member` are privilege; `:service` is a kind, and `admin?/1` is false for
  it, so a machine cannot pass the admin gate whatever its token says. Synthetic subjects
  are namespaced (`breakglass:`, `service:`) to stay clear of anything an issuer mints,
  and both synthesise an email because the column is `null: false`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @type t :: %__MODULE__{}

  schema "users" do
    field :sub, :string
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :role, Ecto.Enum, values: [:admin, :member, :service], default: :member
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
    |> validate_inclusion(:role, [:admin, :member, :service])
  end
end
