defmodule Homelab.AccountsOidcProvisioningTest do
  @moduledoc """
  `get_or_create_from_oidc/1` inserted a user for ANY unseen `sub`. No allowlist, no
  email-domain check, no group or claim requirement, no first-user-only gate — whoever
  the issuer would mint a token for got an account here.

  On its own that is a shared-issuer problem (a public Google or GitHub OIDC app means
  the entire internet can sign in). Combined with the role enum being unenforced, it
  meant any such account arrived with full control of the box.

  These tests are `async: false`: `Homelab.Settings` caches in a global ETS table that
  does not roll back with the SQL sandbox.
  """
  use Homelab.DataCase, async: false

  alias Homelab.Accounts
  alias Homelab.Settings

  import Homelab.Factory

  setup do
    Settings.reset_cache()
    on_exit(&Settings.reset_cache/0)
    :ok
  end

  defp oidc(sub, email), do: %{"sub" => sub, "email" => email, "name" => "Someone"}

  describe "the first user" do
    test "is provisioned, and is an administrator" do
      assert {:ok, user} = Accounts.get_or_create_from_oidc(oidc("first", "owner@example.com"))
      assert user.role == :admin
    end

    test "is only the first — the second unknown sub is refused" do
      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("first", "owner@example.com"))

      assert {:error, :not_allowed} =
               Accounts.get_or_create_from_oidc(oidc("second", "stranger@example.com"))

      assert length(Accounts.list_users()) == 1
    end

    test "does not become an administrator by accident once one exists" do
      insert(:user, role: :admin)
      Settings.set("oidc_allowed_emails", "later@example.com")

      assert {:ok, user} = Accounts.get_or_create_from_oidc(oidc("later", "later@example.com"))
      assert user.role == :member
    end
  end

  describe "a known sub" do
    test "is always let through — the gate is about provisioning, not sign-in" do
      insert(:user, role: :admin)
      insert(:user, sub: "known", email: "known@example.com", role: :member)

      assert {:ok, user} =
               Accounts.get_or_create_from_oidc(%{
                 "sub" => "known",
                 "email" => "known@example.com",
                 "name" => "Renamed"
               })

      assert user.name == "Renamed"
      # An existing member is not promoted by signing in again — not while the instance
      # already has an administrator, anyway. See "an instance with no administrator".
      assert user.role == :member
    end
  end

  describe "an instance with no administrator" do
    # The first-user rule only helps NEW installs. An instance that predates enforcement
    # can hold nothing but members: `role` defaults to :member and, until now, the only
    # writer of :admin was a break-glass login. Left alone, upgrading such an instance
    # means every admin-gated action is unreachable by everyone, recoverable only from a
    # break-glass token placed in advance.
    #
    # So signing in repairs it. Deterministically the OLDEST account, never whoever
    # happens to log in first — the person who set the box up is the owner, and a
    # land-grab would be a worse answer than the lockout.
    test "promotes its oldest account when someone signs in" do
      first = insert(:user, sub: "first", role: :member)
      second = insert(:user, sub: "second", role: :member)

      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("second", second.email))

      assert Accounts.get_user(first.id).role == :admin
      assert Accounts.get_user(second.id).role == :member
    end

    test "leaves an instance that already has one alone" do
      admin = insert(:user, sub: "the-admin", role: :admin)
      member = insert(:user, sub: "a-member", role: :member)

      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("a-member", member.email))

      assert Accounts.get_user(admin.id).role == :admin
      assert Accounts.get_user(member.id).role == :member
    end
  end

  describe "the allowlist" do
    setup do
      insert(:user, role: :admin)
      :ok
    end

    test "admits an exact email" do
      Settings.set("oidc_allowed_emails", "alice@example.com, bob@example.com")

      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("bob", "bob@example.com"))

      assert {:error, :not_allowed} =
               Accounts.get_or_create_from_oidc(oidc("eve", "eve@evil.com"))
    end

    test "admits a whole domain written with a leading @" do
      Settings.set("oidc_allowed_emails", "@example.com")

      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("carol", "carol@example.com"))

      assert {:error, :not_allowed} =
               Accounts.get_or_create_from_oidc(oidc("mallory", "mallory@example.com.evil.com"))
    end

    test "is case-insensitive and tolerates newline-separated entries" do
      Settings.set("oidc_allowed_emails", "Alice@Example.com\n@Other.Org\n")

      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("alice", "ALICE@example.com"))
      assert {:ok, _} = Accounts.get_or_create_from_oidc(oidc("dave", "dave@OTHER.org"))
    end

    test "refuses a claim with no usable email rather than guessing" do
      Settings.set("oidc_allowed_emails", "@example.com")

      assert {:error, :not_allowed} =
               Accounts.get_or_create_from_oidc(%{"sub" => "no-email", "name" => "Nobody"})
    end
  end

  describe "the explicit opt-in" do
    test "restores the old any-subject behaviour when an operator asks for it" do
      insert(:user, role: :admin)
      Settings.set("oidc_auto_provision", "true")

      assert {:ok, user} = Accounts.get_or_create_from_oidc(oidc("anyone", "anyone@example.com"))
      assert user.role == :member
    end

    test "any other value leaves the gate shut" do
      insert(:user, role: :admin)
      Settings.set("oidc_auto_provision", "false")

      assert {:error, :not_allowed} =
               Accounts.get_or_create_from_oidc(oidc("anyone", "anyone@example.com"))
    end
  end
end
