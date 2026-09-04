defmodule Homelab.Accounts.User do
  @moduledoc """
  A principal this instance has seen: a person, or a machine.

  `role` carries two different kinds of fact, which is worth naming because the enum
  reads as one scale and is not:

    * `:admin` and `:member` are PRIVILEGE, and the split is read-vs-write. Only
      `:admin` satisfies `Homelab.Accounts.admin?/1`, which every layer asks.
    * `:service` is a KIND. It marks a row that stands in for an OAuth client
      authenticating with `client_credentials` — an agent, not a person. It is
      deliberately not a rung on the privilege ladder: `admin?/1` is false for it, so a
      machine principal cannot pass `RequireAdmin`/`RequireAdminApi` no matter what its
      token says. What a machine may actually do is decided per-request from the scopes
      on the token it presented, which leaves the admin gate as a ceiling that holds
      even if that scope mapping is wrong.

  `sub` is the natural key and it is unique, so synthetic subjects are namespaced by
  prefix to keep them clear of anything an issuer might mint: `breakglass:` for
  `Homelab.Accounts.get_or_create_breakglass_admin/1`, `service:` for
  `Homelab.Accounts.get_or_create_service_account/1`.

  `email` is `null: false`, which both synthetic principals have to satisfy without
  having one — break-glass synthesises `@breakglass.local`, a service account
  `@service.local`. Neither domain resolves, which is the point.
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
