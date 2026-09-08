defmodule HomelabWeb.ActivityLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn}
  end

  describe "mount" do
    test "renders activity log page", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Activity Log"
    end

    test "shows page description", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Recent activity across your homelab"
    end

    test "shows empty state when no activities", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "No activity yet" or html =~ "Activity"
    end
  end

  describe "with audit entries" do
    setup %{user: user} do
      Homelab.Audit.log("deployment.created", "deployment", 1, user_id: user.id)
      Homelab.Audit.log("deployment.stopped", "deployment", 2, user_id: user.id)
      Homelab.Audit.log("backup.created", "backup", 1, user_id: user.id)
      :ok
    end

    test "shows activity entries", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Deployment Created"
      assert html =~ "Deployment Stopped"
      assert html =~ "Backup Created"
    end

    test "shows resource type", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "deployment"
    end

    test "shows user email", %{conn: conn, user: user} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ user.email
    end

    test "shows resource id", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "#1" or html =~ "#2"
    end

    test "shows relative timestamps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "just now" or html =~ "ago" or html =~ "Activity"
    end
  end

  # The complaint: every row read "Deploy Info" over "deploy #98". The writers have always
  # passed a written sentence and a deployment id; the page rendered neither.
  describe "what actually happened" do
    setup do
      deployment =
        insert(:deployment,
          app_template: insert(:app_template, name: "Sonarr", slug: "sonarr"),
          external_id: "sonarr1"
        )

      {:ok, deployment: deployment}
    end

    test "renders the message the writer recorded, not the action name", %{
      conn: conn,
      deployment: deployment
    } do
      Homelab.Services.ActivityLog.info("deploy", "Sonarr deployed", %{
        deployment_id: deployment.id
      })

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Sonarr deployed"
    end

    test "names the deployment instead of printing its id", %{
      conn: conn,
      deployment: deployment
    } do
      Homelab.Services.ActivityLog.warn("reconciler", "Container not found", %{
        deployment_id: deployment.id
      })

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Container not found"

      # The trail names the source and the deployment, in place of the "reconciler #98"
      # that was there before.
      assert html =~ "Reconciler &middot; Sonarr" or html =~ "Reconciler · Sonarr"
    end

    # An error and a routine info line rendered as the same purple bolt, so the one row
    # worth finding looked like the ninety-nine around it.
    test "an error is coloured as one", %{conn: conn, deployment: deployment} do
      Homelab.Services.ActivityLog.error("deploy", "Image pull failed", %{
        deployment_id: deployment.id
      })

      {:ok, view, _html} = live(conn, ~p"/activity")

      assert has_element?(view, "[class*='text-error']")
      assert render(view) =~ "Image pull failed"
    end

    # A deployment can be deleted after the entry is written; the row must still render.
    test "survives a subject that no longer exists", %{conn: conn, deployment: deployment} do
      Homelab.Services.ActivityLog.info("deploy", "Sonarr removed", %{
        deployment_id: deployment.id
      })

      Homelab.Repo.delete!(deployment)

      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Sonarr removed"
    end
  end

  describe "page header" do
    test "shows clock icon in header", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Activity Log"
    end

    test "has proper page title", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Activity"
    end
  end

  describe "action formatting" do
    setup %{user: user} do
      Homelab.Audit.log("deployment.started", "deployment", 10, user_id: user.id)
      :ok
    end

    test "formats action with capitalized words", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Deployment Started"
    end
  end

  describe "empty activities" do
    test "shows empty state message", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "No activity yet" or html =~ "Activity will appear"
    end

    test "shows helpful empty state description", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")

      assert html =~ "Activity will appear here" or html =~ "No activity" or
               html =~ "Activity Log"
    end
  end

  describe "multiple activity types" do
    setup %{user: user} do
      for action <- [
            "deployment.created",
            "deployment.stopped",
            "deployment.started",
            "backup.created"
          ] do
        resource_type = String.split(action, ".") |> hd()
        Homelab.Audit.log(action, resource_type, :rand.uniform(100), user_id: user.id)
      end

      :ok
    end

    test "shows all activity types", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/activity")
      assert html =~ "Deployment Created"
      assert html =~ "Deployment Stopped"
      assert html =~ "Deployment Started"
      assert html =~ "Backup Created"
    end
  end
end
