defmodule Homelab.AccountsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Accounts
  import Homelab.Factory

  describe "get_user/1" do
    test "returns user by integer id" do
      user = insert(:user)
      assert fetched = Accounts.get_user(user.id)
      assert fetched.id == user.id
    end

    test "returns nil for non-existent id" do
      assert Accounts.get_user(0) == nil
    end

    test "returns nil for non-integer input" do
      assert Accounts.get_user("abc") == nil
      assert Accounts.get_user(nil) == nil
    end
  end

  describe "get_user_by_sub/1" do
    test "returns user matching sub claim" do
      user = insert(:user, sub: "oidc|12345")
      assert fetched = Accounts.get_user_by_sub("oidc|12345")
      assert fetched.id == user.id
    end

    test "returns nil for unknown sub" do
      assert Accounts.get_user_by_sub("nonexistent") == nil
    end

    test "returns nil for non-binary input" do
      assert Accounts.get_user_by_sub(nil) == nil
      assert Accounts.get_user_by_sub(123) == nil
    end
  end

  describe "get_or_create_from_oidc/1" do
    test "creates a new user from OIDC attrs" do
      attrs = %{
        "sub" => "new-sub-1",
        "email" => "new@example.com",
        "name" => "New User",
        "picture" => "https://example.com/avatar.png"
      }

      assert {:ok, user} = Accounts.get_or_create_from_oidc(attrs)
      assert user.sub == "new-sub-1"
      assert user.email == "new@example.com"
      assert user.name == "New User"
      assert user.avatar_url == "https://example.com/avatar.png"
    end

    test "updates an existing user on subsequent calls" do
      insert(:user, sub: "existing-sub", email: "old@example.com", name: "Old Name")

      attrs = %{
        "sub" => "existing-sub",
        "email" => "new@example.com",
        "name" => "New Name"
      }

      assert {:ok, user} = Accounts.get_or_create_from_oidc(attrs)
      assert user.email == "new@example.com"
      assert user.name == "New Name"
    end

    test "works with atom keys" do
      attrs = %{sub: "atom-sub", email: "atom@test.com", name: "Atom User"}
      assert {:ok, user} = Accounts.get_or_create_from_oidc(attrs)
      assert user.sub == "atom-sub"
    end
  end

  describe "list_users/0" do
    test "returns all users" do
      insert(:user)
      insert(:user)
      assert length(Accounts.list_users()) == 2
    end

    test "returns empty list when no users exist" do
      assert Accounts.list_users() == []
    end
  end

  describe "update_user/2" do
    test "updates user attributes" do
      user = insert(:user)
      assert {:ok, updated} = Accounts.update_user(user, %{name: "Updated Name"})
      assert updated.name == "Updated Name"
    end

    test "returns error for invalid attrs" do
      user = insert(:user)
      assert {:error, changeset} = Accounts.update_user(user, %{email: nil})
      assert errors_on(changeset)[:email] != nil
    end
  end

  describe "the last administrator" do
    # Enforcement now depends on an admin existing: RequireAdmin lets everyone through
    # while the instance has none, so that an install which never had one is not locked
    # out of the only page that can appoint one. Demoting the last admin would drive the
    # count back to zero and silently re-open that exemption to every signed-in user —
    # while the UI still shows a role selector implying enforcement.
    #
    # The guard lives here rather than at the LiveView that happens to call it today:
    # it is an invariant of the account model, and it has to hold for the API and for
    # anything written later too.
    test "cannot be demoted" do
      admin = insert(:user, role: :admin)

      assert {:error, changeset} = Accounts.update_user(admin, %{role: :member})
      assert errors_on(changeset)[:role] != nil
      assert Accounts.get_user(admin.id).role == :admin
    end

    test "is still an admin afterwards, so the exemption stays shut" do
      admin = insert(:user, role: :admin)
      insert(:user, role: :member)

      assert {:error, _} = Accounts.update_user(admin, %{role: :member})
      assert Accounts.any_admin?()
    end

    test "is only the LAST one — one of two can be demoted" do
      insert(:user, role: :admin)
      other = insert(:user, role: :admin)

      assert {:ok, updated} = Accounts.update_user(other, %{role: :member})
      assert updated.role == :member
      assert Accounts.any_admin?()
    end

    test "can still be edited, as long as the role is not what changes" do
      admin = insert(:user, role: :admin)

      assert {:ok, updated} = Accounts.update_user(admin, %{name: "Still The Admin"})
      assert updated.name == "Still The Admin"
      assert updated.role == :admin
    end

    test "last_admin?/1 is public so a caller can refuse before it tries" do
      admin = insert(:user, role: :admin)
      member = insert(:user, role: :member)

      assert Accounts.last_admin?(admin)
      refute Accounts.last_admin?(member)

      insert(:user, role: :admin)
      refute Accounts.last_admin?(admin)
    end
  end

  describe "update_last_login/1" do
    test "sets last_login_at to current time" do
      user = insert(:user, last_login_at: nil)
      assert {:ok, updated} = Accounts.update_last_login(user)
      assert updated.last_login_at != nil
    end
  end
end
