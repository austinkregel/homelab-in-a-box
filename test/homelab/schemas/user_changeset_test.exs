defmodule Homelab.Schemas.UserChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Accounts.User

  @valid_attrs %{sub: "oidc-123", email: "person@example.com"}

  defp changeset(attrs), do: User.changeset(%User{}, attrs)

  describe "changeset/2 required fields" do
    test "is valid with sub and email" do
      assert changeset(@valid_attrs).valid?
    end

    test "requires sub and email" do
      cs = changeset(%{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.sub
      assert "can't be blank" in errors.email
    end

    test "requires sub when email present" do
      cs = changeset(%{email: "x@example.com"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).sub
    end

    test "requires email when sub present" do
      cs = changeset(%{sub: "oidc-x"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).email
    end
  end

  describe "changeset/2 optional fields and role" do
    test "casts name and avatar_url" do
      cs = changeset(Map.merge(@valid_attrs, %{name: "Jane", avatar_url: "http://x/y.png"}))
      assert cs.valid?
      assert get_change(cs, :name) == "Jane"
      assert get_change(cs, :avatar_url) == "http://x/y.png"
    end

    test "accepts admin and member roles" do
      assert changeset(Map.put(@valid_attrs, :role, :admin)).valid?
      assert changeset(Map.put(@valid_attrs, :role, :member)).valid?
    end

    test "rejects an invalid role" do
      cs = changeset(Map.put(@valid_attrs, :role, :superuser))
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :role)
    end

    test "defaults role to member on insert" do
      {:ok, user} = %User{} |> User.changeset(@valid_attrs) |> Repo.insert()
      assert user.role == :member
    end

    test "does not cast last_login_at (not in cast list)" do
      cs = changeset(Map.put(@valid_attrs, :last_login_at, DateTime.utc_now()))
      assert get_change(cs, :last_login_at) == nil
    end
  end

  describe "unique constraints" do
    test "rejects a duplicate sub" do
      existing = insert(:user)

      {:error, cs} =
        %User{}
        |> User.changeset(%{sub: existing.sub, email: "fresh@example.com"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).sub
    end

    test "rejects a duplicate email" do
      existing = insert(:user)

      {:error, cs} =
        %User{}
        |> User.changeset(%{sub: "totally-new-sub", email: existing.email})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).email
    end

    test "inserts successfully with unique sub and email" do
      assert {:ok, _} =
               %User{}
               |> User.changeset(%{sub: "unique-sub-99", email: "unique99@example.com"})
               |> Repo.insert()
    end
  end
end
