defmodule HomelabWeb.Plugs.RequireAdminTest do
  @moduledoc """
  `users.role` existed as an `Ecto.Enum [:admin, :member]`, was editable from the
  Settings page, and was read by exactly one thing: `Accounts.list_admins/0`, to pick
  notification recipients. Nothing anywhere enforced it. `grep -rn ':admin'
  lib/homelab_web/` returned a single hit and it was an `<option>` tag.

  So every authenticated user was an administrator in practice. That mattered most on
  Settings, because Settings is where privilege is granted (the role dropdown) and where
  authentication itself can be switched back off (`rerun_setup` deletes
  `setup_completed`, and `RequireAuth` deliberately fails open while setup is
  incomplete). A member could therefore promote themselves, or disable auth for the
  whole app.

  These tests drive the router, not the plug module, so they fail the way a user would
  experience the hole rather than the way the implementation is shaped — both the
  `:browser` plug and the LiveView `on_mount` hook have to be wired for them to pass.
  """
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory
  import Phoenix.LiveViewTest

  alias Homelab.Accounts

  defp member_conn(conn) do
    member = insert(:user, role: :member)
    {log_in_user(conn, member), member}
  end

  describe "the Settings LiveView" do
    test "an admin can open it", %{conn: conn, user: user} do
      assert user.role == :admin
      assert {:ok, _view, _html} = live(conn, ~p"/settings")
    end

    test "a member cannot open it", %{conn: conn} do
      {conn, _member} = member_conn(conn)

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")
    end

    test "a member is still sent to the login page when not signed in at all", %{conn: conn} do
      # Ordering matters: :require_auth has to run before :require_admin, or an
      # anonymous visitor gets the "not an administrator" answer instead of a login.
      conn = delete_session(conn, :user_id)

      assert {:error, {:redirect, %{to: "/auth/oidc"}}} = live(conn, ~p"/settings")
    end
  end

  describe "the settings export endpoint" do
    test "an admin can download it", %{conn: conn} do
      conn = get(conn, ~p"/settings/export")

      assert conn.status == 200
      assert %{"settings" => _} = Jason.decode!(conn.resp_body)
    end

    test "a member cannot, and gets none of the config back", %{conn: conn} do
      {conn, _member} = member_conn(conn)

      conn = get(conn, ~p"/settings/export")

      assert redirected_to(conn) == "/"
      refute conn.resp_body =~ "settings"
    end
  end

  describe "the bootstrap exemption" do
    test "with no admin on the instance, a member is let through", %{conn: conn, user: user} do
      # Mirrors the exemption `RequireAuth` already makes for incomplete setup. `role`
      # defaults to :member and, before this change, nothing ever set :admin except a
      # break-glass login — so an existing instance can genuinely have zero admins, and
      # a strict gate would brick the only page that can create one.
      # Written straight to the row, not through `update_user/2` — that now refuses to
      # demote the last admin, so this state is unreachable through the app. Which is
      # the point: it is a LEGACY state, what an instance that predates enforcement
      # looks like, and the exemption exists only to get such an instance back on its
      # feet.
      user |> Ecto.Changeset.change(%{role: :member}) |> Homelab.Repo.update!()
      {conn, _member} = member_conn(conn)

      assert Accounts.list_admins() == []
      assert {:ok, _view, _html} = live(conn, ~p"/settings")
    end

    test "the exemption closes the moment one admin exists", %{conn: conn} do
      {conn, _member} = member_conn(conn)

      assert Accounts.list_admins() != []
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")
    end

    test "and cannot be re-opened by demoting the only administrator", %{
      conn: conn,
      user: only_admin
    } do
      # The exemption is only safe if it is a one-way door. Nothing stopped the admin
      # count going 1 -> 0, which would hand every signed-in user the run of Settings
      # again — silently, with the role selector still on screen implying otherwise.
      {member_conn, _member} = member_conn(conn)

      assert {:error, _} = Accounts.update_user(only_admin, %{role: :member})

      assert Accounts.any_admin?()
      assert {:error, {:redirect, %{to: "/"}}} = live(member_conn, ~p"/settings")
    end
  end

  describe "Accounts.admin?/1" do
    # The predicate is public so the plug, the on_mount hook, and any LiveView that needs
    # to hide or refuse a privileged action all answer the question the same way instead
    # of growing separate, drifting definitions.
    test "answers for a user, and refuses anything else" do
      assert Accounts.admin?(build(:user, role: :admin))
      refute Accounts.admin?(build(:user, role: :member))
      refute Accounts.admin?(nil)
    end
  end
end
