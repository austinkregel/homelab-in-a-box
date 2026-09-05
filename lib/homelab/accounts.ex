defmodule Homelab.Accounts do
  @moduledoc """
  Context for user accounts.
  """
  require Logger

  alias Homelab.Repo
  alias Homelab.Accounts.User
  alias Homelab.Settings

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

  A `sub` this instance has seen before always signs in — the gate below is about
  PROVISIONING, not authentication, and an existing user's role is never changed by
  signing in again.

  An unknown `sub` is only provisioned when one of these says yes:

    * **it is the first user.** Somebody has to be able to get in, and they become the
      `:admin` — otherwise a fresh install is born with no administrator and no way to
      appoint one.
    * **`oidc_allowed_emails` matches.** Comma- or newline-separated; an entry is either
      a full address or a domain written `@example.com`. Case-insensitive. A domain entry
      matches the address's domain exactly, never as a suffix, so `@example.com` does not
      admit `evil@example.com.attacker.net`.
    * **`oidc_auto_provision` is `"true"`.** The old behaviour, kept as an explicit
      opt-in for anyone whose issuer is already the access boundary (a private IdP that
      only holds the accounts it should).

  Otherwise `{:error, :not_allowed}`. This matters because the issuer is frequently NOT
  an access boundary: a public Google or GitHub OIDC app will mint a token for anyone
  alive, and every such account used to land here with full control of the Docker host.
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
        provision_from_oidc(oidc_attrs)

      user ->
        user
        |> User.changeset(oidc_attrs)
        |> Repo.update()
    end
  end

  defp provision_from_oidc(oidc_attrs) do
    cond do
      not Repo.exists?(User) ->
        %User{}
        |> User.changeset(Map.put(oidc_attrs, :role, :admin))
        |> Repo.insert()

      provisioning_allowed?(oidc_attrs.email) ->
        %User{}
        |> User.changeset(Map.put(oidc_attrs, :role, :member))
        |> Repo.insert()

      true ->
        Logger.warning(
          "OIDC provisioning refused for sub=#{inspect(oidc_attrs.sub)} " <>
            "email=#{inspect(oidc_attrs.email)}: not on oidc_allowed_emails and " <>
            "oidc_auto_provision is not enabled."
        )

        {:error, :not_allowed}
    end
  end

  defp provisioning_allowed?(email) do
    Settings.get("oidc_auto_provision") == "true" or email_allowed?(email)
  end

  defp email_allowed?(email) when is_binary(email) do
    email = String.downcase(String.trim(email))
    domain = email |> String.split("@") |> List.last()

    "oidc_allowed_emails"
    |> Settings.get("")
    |> to_string()
    |> String.split([",", "\n"], trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
    |> Enum.any?(fn
      "@" <> allowed_domain -> allowed_domain == domain
      allowed_email -> allowed_email == email
    end)
  end

  defp email_allowed?(_), do: false

  @doc """
  Gets or creates the local break-glass admin user.

  This is the identity a successful `Homelab.Auth.BreakGlass` login assumes. It
  is a real `:admin` row, keyed on a synthetic `sub` so it never collides with an
  OIDC-provisioned user. The `label` only affects the synthetic sub/email, so the
  same operator always maps to the same row across break-glass logins.
  """
  def get_or_create_breakglass_admin(label \\ "breakglass") when is_binary(label) do
    sub = "breakglass:#{label}"

    case get_user_by_sub(sub) do
      nil ->
        %User{}
        |> User.changeset(%{
          sub: sub,
          email: "#{label}@breakglass.local",
          name: "Break-glass Admin",
          role: :admin
        })
        |> Repo.insert()

      user ->
        {:ok, user}
    end
  end

  @doc """
  Gets or creates the row standing in for a machine principal.

  `attrs` is the issuer's machine-info body (`client_id`, `name`, `scopes`). The row
  exists so the audit trail has something to name, and it is the machine's own row so an
  agent's writes never carry an operator's name.

  Deliberately not `get_or_create_from_oidc/1`: that one makes the first `sub` to arrive
  an `:admin`, which on a fresh box would hand the Docker host to whichever agent
  authenticated first. Scopes are ignored — they live in the issuer.
  """
  def get_or_create_service_account(attrs) when is_map(attrs) do
    case client_id(attrs) do
      nil ->
        {:error, :missing_client_id}

      client_id ->
        sub = "service:#{client_id}"

        case get_user_by_sub(sub) do
          nil ->
            %User{}
            |> User.changeset(%{
              sub: sub,
              email: "#{client_id}@service.local",
              name: service_name(attrs, client_id),
              role: :service
            })
            |> Repo.insert()

          user ->
            {:ok, user}
        end
    end
  end

  # An issuer may send a number; "7" and 7 must not become two rows for one credential.
  defp client_id(attrs) do
    case Map.get(attrs, "client_id") || Map.get(attrs, :client_id) do
      id when is_binary(id) -> if String.trim(id) == "", do: nil, else: String.trim(id)
      id when is_integer(id) -> Integer.to_string(id)
      _ -> nil
    end
  end

  # The only human-readable handle for an agent in the activity log, and often unset.
  defp service_name(attrs, client_id) do
    case Map.get(attrs, "name") || Map.get(attrs, :name) do
      name when is_binary(name) ->
        if String.trim(name) == "", do: "Service #{client_id}", else: String.trim(name)

      _ ->
        "Service #{client_id}"
    end
  end

  @doc """
  Lists every principal, people and machines alike.

  Service accounts sort last rather than being hidden — a machine credential nobody can
  see is one nobody thinks to revoke. Ties break on `id` so renders are stable.
  """
  def list_users do
    import Ecto.Query

    Repo.all(
      from u in User,
        order_by: [
          asc: fragment("CASE WHEN ? = 'service' THEN 1 ELSE 0 END", u.role),
          asc: u.id
        ]
    )
  end

  @doc """
  Lists all admin users (recipients for system alerts).
  """
  def list_admins do
    import Ecto.Query
    Repo.all(from u in User, where: u.role == :admin)
  end

  @doc """
  Whether this user is an administrator.

  Public, and takes the user rather than a conn or a socket, so the plug, the LiveView
  `on_mount` hook, and any view that needs to hide or refuse a privileged control all
  answer the question the same way instead of growing separate, drifting definitions.
  `nil` (nobody signed in) is not an administrator.
  """
  @spec admin?(User.t() | nil) :: boolean()
  def admin?(%User{role: :admin}), do: true
  def admin?(_), do: false

  @doc "Whether this principal is a machine rather than a person."
  @spec service?(User.t() | nil) :: boolean()
  def service?(%User{role: :service}), do: true
  def service?(_), do: false

  @doc """
  Whether this user is the only administrator left.

  Public so a caller can refuse before it tries, and say why — `update_user/2` returns
  an ordinary changeset error, which reads as "invalid" rather than "not allowed".
  """
  @spec last_admin?(User.t() | nil) :: boolean()
  def last_admin?(%User{role: :admin, id: id}) do
    import Ecto.Query

    Repo.one(from u in User, where: u.role == :admin, select: count()) == 1 and
      Repo.exists?(from u in User, where: u.role == :admin and u.id == ^id)
  end

  def last_admin?(_), do: false

  @doc """
  Updates a user.

  Refuses to demote the last administrator, and refuses to move any row into or out of
  `:service`. Both come back as an error on `:role`.

  That refusal lives here rather than at the one LiveView that calls it today because it
  is an invariant of the account model, and nothing else defends it: there is no delete
  or deactivate to route around, and demoting the last administrator would leave the
  instance with no way to reach Settings at all — recoverable only from a break-glass
  token. The API and anything written later need the same answer.
  """
  def update_user(%User{} = user, attrs) do
    user
    |> User.changeset(attrs)
    |> refuse_last_admin_demotion(user)
    |> refuse_service_role_change(user)
    |> Repo.update()
  end

  # `:service` is a kind, not a rung: promoting one breaches the admin ceiling, demoting it
  # reclassifies a robot as a person. Reachable via `String.to_existing_atom/1` on form input.
  defp refuse_service_role_change(changeset, user) do
    new_role = Ecto.Changeset.get_field(changeset, :role)

    cond do
      user.role == :service and new_role != :service ->
        Ecto.Changeset.add_error(
          changeset,
          :role,
          "cannot be changed: a service account's privileges come from its token, not its role"
        )

      user.role != :service and new_role == :service ->
        Ecto.Changeset.add_error(
          changeset,
          :role,
          "cannot be set: service accounts are created from a machine token, not by promotion"
        )

      true ->
        changeset
    end
  end

  defp refuse_last_admin_demotion(changeset, user) do
    demoting? =
      user.role == :admin and Ecto.Changeset.get_field(changeset, :role) != :admin

    if demoting? and last_admin?(user) do
      Ecto.Changeset.add_error(
        changeset,
        :role,
        "cannot be changed: this is the only administrator left"
      )
    else
      changeset
    end
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
