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
      {conn, member} = member_conn(conn)

      # Pinned, because the whole suite's blind spot is that it never has one:
      # `test/support/factory.ex` defaults `role: :admin`, so every `insert(:user)`
      # anywhere else is an administrator and could not observe this refusal.
      assert member.role == :member
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

  describe "an instance with no administrator at all" do
    test "does not become an instance where everyone is one", %{conn: conn, user: user} do
      # An earlier draft exempted this state, reasoning that a strict gate would lock an
      # upgrading instance out of the only page that can appoint an admin. That premise
      # is false: `get_or_create_breakglass_admin/1` inserts with role: :admin, so
      # break-glass IS the promotion path. And the exemption was reachable rather than
      # hypothetical — demote your way to zero and everyone signed in is an
      # administrator, which is the very thing the last-admin guard exists to prevent,
      # entered through the other door.
      #
      # Written straight to the row because `update_user/2` now refuses to get here.
      user |> Ecto.Changeset.change(%{role: :member}) |> Homelab.Repo.update!()
      {conn, _member} = member_conn(conn)

      assert Accounts.list_admins() == []
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/settings")
    end
  end

  describe "the LiveView hook, on its own" do
    test "refuses a member and admits an administrator" do
      # The plug and the hook are separate layers and only one of them is observable
      # through the router: the plug halts the HTTP request first, so `live(conn, ...)`
      # never reaches the mount. Delete the hook and every routed test above still
      # passes. So ask the hook directly.
      assert {:halt, _socket} = mount_as(insert(:user, role: :member))
      assert {:cont, _socket} = mount_as(insert(:user, role: :admin))
    end

    test "refuses when nobody is signed in, rather than crashing on a missing assign" do
      assert {:halt, _socket} = mount_as(nil)
    end

    defp mount_as(user) do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, flash: %{}, current_user: user}
      }

      HomelabWeb.Live.Hooks.on_mount(:require_admin, %{}, %{}, socket)
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
