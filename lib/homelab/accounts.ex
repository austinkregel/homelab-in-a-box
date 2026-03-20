defmodule Homelab.Accounts do
  @moduledoc """
  Context for user accounts.
  """
  alias Homelab.Repo
  alias Homelab.Accounts.User

  @doc """
  Gets a single user by id.
  """
  def get_user(id) when is_integer(id) do
    Repo.get(User, id)
  end

  def get_user(_), do: nil

  @doc """
  Gets a user by OIDC subject (sub) claim.
  """
  def get_user_by_sub(sub) when is_binary(sub) do
    Repo.get_by(User, sub: sub)
  end

  def get_user_by_sub(_), do: nil

  @doc """
  Gets or creates a user from OIDC userinfo.

  Expects a map with "sub", "email", "name", and optionally "picture" keys.
  Upserts based on the sub claim.
  """
  def get_or_create_from_oidc(attrs) when is_map(attrs) do
    sub = Map.get(attrs, "sub") || Map.get(attrs, :sub)
    email = Map.get(attrs, "email") || Map.get(attrs, :email)
    name = Map.get(attrs, "name") || Map.get(attrs, :name)
    picture = Map.get(attrs, "picture") || Map.get(attrs, :picture)

    oidc_attrs = %{
      sub: sub,
      email: email,
      name: name,
      avatar_url: picture
    }

    case get_user_by_sub(sub) do
      nil ->
        %User{}
        |> User.changeset(oidc_attrs)
        |> Repo.insert()

      user ->
        user
        |> User.changeset(oidc_attrs)
        |> Repo.update()
    end
  end

  @doc """
  Lists all users.
  """
  def list_users do
    Repo.all(User)
  end

  @doc """
  Updates a user.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Updates the last login timestamp for a user.
  """
  def update_last_login(%User{} = user) do
    user
    |> Ecto.Changeset.change(%{last_login_at: DateTime.utc_now() |> DateTime.truncate(:second)})
    |> Repo.update()
  end
end
