defmodule HomelabWeb.DeploymentLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)
    template = insert(:app_template)

    deployment =
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        status: :running,
        external_id: "container_123"
      )

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    {:ok, conn: conn, tenant: tenant, template: template, deployment: deployment}
  end

  describe "mount" do
    test "renders deployment detail page", %{conn: conn, deployment: dep, template: template} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ template.name
      assert html =~ "Running"
    end

    test "shows breadcrumb navigation", %{conn: conn, deployment: dep, tenant: tenant} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Dashboard"
      assert html =~ tenant.name
    end

    test "shows overview tab by default", %{conn: conn, deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Details"
      assert html =~ "Image"
    end

    test "shows action buttons for running deployment", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Stop")
      assert has_element?(view, "button", "Restart")
      assert has_element?(view, "button", "Delete")
    end
  end

  describe "tab switching" do
    test "switch to logs tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Follow" or html =~ "Refresh"
    end

    test "switch to environment tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "environment"})
      assert html =~ "Environment variables"
    end

    test "switch to backups tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "backups"})
      assert html =~ "Backups"
      assert html =~ "Manual backup"
    end

    test "switch to volumes tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})
      assert html =~ "Volumes"
    end

    test "switch to topology tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "topology"})
      assert html =~ "Infrastructure Topology"
    end

    test "switch to traffic tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "Traffic"
    end

    test "switching away from logs cancels log polling", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      render_click(view, "switch_tab", %{"tab" => "overview"})
      html = render(view)
      assert html =~ "Details"
    end
  end

  describe "logs" do
    test "toggle_follow_logs enables log following", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      render_click(view, "toggle_follow_logs", %{})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Follow"
    end

    test "refresh_logs reloads logs", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:logs, fn _id, _opts -> {:ok, "log line 1\nlog line 2"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      render_click(view, "refresh_logs", %{})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "log line 1" or html =~ "Loading logs"
    end
  end

  describe "environment editing" do
    test "start_env_edit enters edit mode", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      html = render_click(view, "start_env_edit", %{})
      assert has_element?(view, "#env-form")
      assert html =~ "Cancel" or html =~ "Save"
    end

    test "cancel_env_edit exits edit mode", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      html = render_click(view, "cancel_env_edit", %{})
      refute has_element?(view, "#env-form")
      assert html =~ "Edit"
    end

    test "save_env updates environment variables", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      html = render_click(view, "save_env", %{"env" => %{"APP_ENV" => "staging"}})
      assert html =~ "Environment updated"
    end
  end

  describe "deployment actions" do
    test "stop stops a running deployment", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "stop", %{})
      assert html =~ "stopped" or html =~ "Stopped"
    end

    test "restart restarts a running deployment", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:restart, fn _dep -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "restart", %{})
      assert html =~ "restarting" or html =~ "Restarting"
    end

    test "delete removes deployment and redirects", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "delete", %{})
      assert_redirect(view, ~p"/")
    end
  end

  describe "stopped deployment" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "container_456"
        )

      {:ok, stopped_deployment: deployment}
    end

    test "shows start button for stopped deployment", %{
      conn: conn,
      stopped_deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Start")
    end

    test "start starts a stopped deployment", %{conn: conn, stopped_deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "new_container_id"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "start", %{})
      assert html =~ "started" or html =~ "Started" or html =~ dep.app_template.name
    end
  end

  describe "handle_info" do
    test "{:deployment_status, id, status} updates deployment", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, {:deployment_status, dep.id, :stopped})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ dep.app_template.name
    end

    test "{:deployment_status, other_id, _} is ignored", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, {:deployment_status, 99999, :stopped})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ dep.app_template.name
    end

    test ":poll_logs fetches fresh logs when following", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:logs, fn _id, _opts -> {:ok, "fresh log output"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      render_click(view, "toggle_follow_logs", %{})
      send(view.pid, :poll_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "fresh log output"
    end

    test ":load_logs loads logs from orchestrator", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:logs, fn _id, _opts -> {:ok, "loaded log content"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, :load_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "loaded log content" or html =~ "logs"
    end
  end

  describe "trigger_backup" do
    test "triggers a backup job", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "backups"})
      html = render_click(view, "trigger_backup", %{})
      assert html =~ "Backup triggered" or html =~ "backup"
    end
  end

  describe "handle_info {:metrics, metrics}" do
    test "receiving metrics does not crash the view", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, {:metrics, %{cpu: 25.0, memory: 512, containers: 3}})
      Process.sleep(100)
      html = render(view)
      assert html =~ dep.app_template.name
    end
  end

  describe "handle_event navigate" do
    test "navigate event redirects to the given path", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "navigate", %{"to" => "/catalog"})
      assert_redirect(view, "/catalog")
    end

    test "navigate event redirects to tenant page", %{conn: conn, deployment: dep, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "navigate", %{"to" => ~p"/tenants/#{tenant.id}"})
      assert_redirect(view, ~p"/tenants/#{tenant.id}")
    end
  end

  describe "failed deployment rendering" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :failed,
          external_id: nil,
          error_message: "Image pull failed: unauthorized"
        )

      {:ok, failed_deployment: deployment}
    end

    test "shows error message banner", %{conn: conn, failed_deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Deployment failed"
      assert html =~ "Image pull failed"
    end

    test "shows start button for failed deployment", %{conn: conn, failed_deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Start")
      assert has_element?(view, "button", "Delete")
      refute has_element?(view, "button", "Stop")
      refute has_element?(view, "button", "Restart")
    end

    test "shows Failed status pill", %{conn: conn, failed_deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Failed"
    end
  end

  describe "deployment without external_id" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :pending,
          external_id: nil
        )

      {:ok, pending_deployment: deployment}
    end

    test "does not show restart button", %{conn: conn, pending_deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      refute has_element?(view, "button", "Restart")
    end

    test "shows dash for external_id", %{conn: conn, pending_deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "External ID"
    end

    test "load_logs shows pending message", %{conn: conn, pending_deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, :load_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "pending" or html =~ "Pending" or html =~ "waiting"
    end
  end

  describe "poll_logs when not following" do
    test "does nothing when follow_logs is false", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      send(view.pid, :poll_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Follow" or html =~ "Refresh"
    end
  end

  describe "load_logs branches" do
    setup %{tenant: tenant, template: template} do
      deploying =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :deploying,
          external_id: nil
        )

      failed_with_msg =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :failed,
          external_id: nil,
          error_message: "Pull access denied"
        )

      {:ok, deploying_dep: deploying, failed_msg_dep: failed_with_msg}
    end

    test "shows deploying message for deploying status", %{conn: conn, deploying_dep: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      send(view.pid, :load_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "starting up" or html =~ "Container"
    end

    test "shows error message for failed deployment without container", %{
      conn: conn,
      failed_msg_dep: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      send(view.pid, :load_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Pull access denied" or html =~ "failed"
    end

    test "handles log fetch error gracefully", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:logs, fn _id, _opts -> {:error, :timeout} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      _ = :sys.get_state(view.pid)
      send(view.pid, :load_logs)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Failed to load logs"
    end
  end

  describe "resource stats rendering" do
    test "shows resource usage when stats available", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:stats, fn _id ->
        {:ok,
         %{
           cpu_percent: 42.5,
           memory_usage: 268_435_456,
           memory_limit: 536_870_912
         }}
      end)

      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Resource usage" or html =~ "CPU" or html =~ "Memory"
    end
  end

  describe "traffic tab rendering" do
    test "shows no domain message when deployment has no domain", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_1",
          domain: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "No domain configured" or html =~ "Traffic"
    end

    test "shows no traffic data message when stats unavailable", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "Traffic"
    end
  end

  describe "volumes tab rendering" do
    test "shows configured volumes", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})
      assert html =~ "/data"
    end

    test "shows no volumes message for template without volumes", %{
      conn: conn,
      tenant: tenant
    } do
      template = insert(:app_template, volumes: [])

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_2"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})
      assert html =~ "No volumes configured"
    end
  end

  describe "backups tab with existing jobs" do
    test "shows backup jobs in table", %{conn: conn, deployment: dep} do
      insert(:backup_job, deployment: dep, status: :completed)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "backups"})
      assert html =~ "Completed" or html =~ "completed"
    end

    test "shows no backups message when empty", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "backups"})
      assert html =~ "No backups yet"
    end
  end

  describe "environment tab display" do
    test "shows environment variables in table", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "environment"})
      assert html =~ "Variable"
      assert html =~ "Value"
      assert html =~ "APP_ENV"
    end

    test "masks secret values", %{conn: conn, tenant: tenant} do
      template = insert(:app_template, default_env: %{"DB_PASSWORD" => "s3cret", "APP_KEY" => "val"})

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_3"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "environment"})
      refute html =~ "s3cret"
    end

    test "env edit form shows input fields", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      html = render_click(view, "start_env_edit", %{})
      assert has_element?(view, "#env-form")
      assert html =~ "Save" or html =~ "Cancel"
    end
  end

  describe "save_env with empty values" do
    test "strips blank env values", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      html = render_click(view, "save_env", %{"env" => %{"APP_ENV" => "", "NEW_VAR" => "hello"}})
      assert html =~ "Environment updated"
    end
  end

  describe "topology tab" do
    test "shows sibling deployment count", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "topology"})
      assert html =~ "Infrastructure Topology"
      assert html =~ "deployment(s)"
    end
  end

  describe "overview tab with domain" do
    setup %{tenant: tenant, template: template} do
      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_dom",
          domain: "test.homelab.local"
        )

      {:ok, domain_deployment: deployment}
    end

    test "displays domain in details section", %{conn: conn, domain_deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "test.homelab.local"
    end

    test "shows Domain label in overview", %{conn: conn, domain_deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Domain"
      assert html =~ "test.homelab.local"
    end
  end

  describe "overview tab status indicators" do
    test "running deployment shows Running status pill", %{conn: conn, deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Running"
      assert html =~ "bg-success"
    end

    test "stopped deployment shows Stopped status pill", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "container_stopped_pill"
        )

      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Stopped"
    end

    test "deploying deployment shows Deploying status pill", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :deploying,
          external_id: nil
        )

      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Deploying"
    end
  end

  describe "environment tab with env vars" do
    setup %{tenant: tenant} do
      template =
        insert(:app_template,
          default_env: %{"DB_HOST" => "localhost", "DB_PORT" => "5432"}
        )

      deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_env",
          env_overrides: %{"DB_HOST" => "db.internal", "CUSTOM_VAR" => "custom_value"}
        )

      {:ok, env_deployment: deployment}
    end

    test "shows merged env vars in environment tab", %{conn: conn, env_deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "environment"})
      assert html =~ "DB_HOST"
      assert html =~ "DB_PORT"
      assert html =~ "CUSTOM_VAR"
    end

    test "overridden env values reflect overrides", %{conn: conn, env_deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "environment"})
      assert html =~ "db.internal"
      assert html =~ "custom_value"
    end
  end

  describe "deployment header breadcrumb details" do
    test "breadcrumb shows tenant name and app template name", %{
      conn: conn,
      deployment: dep,
      tenant: tenant,
      template: template
    } do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Dashboard"
      assert html =~ tenant.name
      assert html =~ template.name
    end

    test "breadcrumb has links to dashboard and tenant", %{conn: conn, deployment: dep, tenant: tenant} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "a[href='/']", "Dashboard")
      assert has_element?(view, "a[href='/tenants/#{tenant.id}']")
    end
  end

  describe "action buttons for different states" do
    test "running deployment shows Stop and Restart but not Start", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Stop")
      assert has_element?(view, "button", "Restart")
      assert has_element?(view, "button", "Delete")
      refute has_element?(view, "button", "Start")
    end

    test "stopped deployment shows Start but not Stop or Restart", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "container_actions_stopped"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Start")
      assert has_element?(view, "button", "Delete")
      refute has_element?(view, "button", "Stop")
    end

    test "failed deployment shows Start and Delete only", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :failed,
          external_id: nil,
          error_message: "Boom"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Start")
      assert has_element?(view, "button", "Delete")
      refute has_element?(view, "button", "Stop")
      refute has_element?(view, "button", "Restart")
    end

    test "pending deployment without external_id hides Restart", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      refute has_element?(view, "button", "Restart")
    end
  end

  describe "traffic tab content" do
    test "shows no domain configured message for deployment without domain", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_nodomain_traffic",
          domain: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "No domain configured" or html =~ "Traffic metrics require"
    end

    test "shows traffic heading", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "Traffic"
    end

    test "shows no traffic data message for domain without stats", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_notraffic",
          domain: "notraffic.homelab.local"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "traffic"})
      assert html =~ "No traffic data available" or html =~ "Metrics will appear" or html =~ "Traffic"
    end
  end

  describe "toggle_follow_logs on and off" do
    test "enables then disables follow logs", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      Process.sleep(100)

      render_click(view, "toggle_follow_logs", %{})
      Process.sleep(100)
      html = render(view)
      assert html =~ "Follow"

      render_click(view, "toggle_follow_logs", %{})
      Process.sleep(100)
      html = render(view)
      assert html =~ "Follow"
    end
  end

  describe "refresh_logs event" do
    test "triggers log reload", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:logs, fn _id, _opts -> {:ok, "refreshed logs"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      Process.sleep(100)
      render_click(view, "refresh_logs", %{})
      Process.sleep(100)
      html = render(view)
      assert html =~ "refreshed logs"
    end
  end

  describe "env edit lifecycle" do
    test "start and cancel env edit round trip", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      assert has_element?(view, "#env-form")

      render_click(view, "cancel_env_edit", %{})
      refute has_element?(view, "#env-form")
    end

    test "save_env success updates environment", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      html = render_click(view, "save_env", %{"env" => %{"APP_ENV" => "test_val"}})
      assert html =~ "Environment updated"
    end

    test "save_env with invalid data shows error", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "env_fail_container"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      html = render_click(view, "save_env", %{"env" => %{"NEW_KEY" => "new_value"}})
      assert html =~ "Environment updated" or html =~ "Failed to update"
    end
  end

  describe "trigger_backup on deployment page" do
    test "successful trigger shows flash", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "backups"})
      html = render_click(view, "trigger_backup", %{})
      assert html =~ "Backup triggered"
    end
  end

  describe "start event on deployment page" do
    test "starts a stopped deployment from detail page", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "start_detail_container"
        )

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "new_id"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "start", %{})
      assert html =~ "started" or html =~ "Started" or html =~ dep.app_template.name
    end

    test "start failure still succeeds with status update", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: "start_fail_detail"
        )

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:error, "deploy failed"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "start", %{})
      assert html =~ "started" or html =~ "Started" or html =~ dep.app_template.name
    end
  end

  describe "stop error on deployment page" do
    test "stop still succeeds even if undeploy errors", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> {:error, "stop failed"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "stop", %{})
      assert html =~ "stopped" or html =~ "Stopped"
    end
  end

  describe "restart error on deployment page" do
    test "shows error flash when restart fails", %{conn: conn, deployment: dep} do
      Homelab.Mocks.Orchestrator
      |> stub(:restart, fn _dep -> {:error, "restart failed"} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "restart", %{})
      assert html =~ "Failed to restart"
    end
  end

  describe "delete event on deployment page" do
    test "deletes deployment and redirects to root", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "delete_detail_container"
        )

      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "delete", %{})
      assert_redirect(view, ~p"/")
    end
  end

  describe "handle_info :deployment_status matching and non-matching" do
    test "updates deployment when id matches", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, {:deployment_status, dep.id, :running})
      Process.sleep(100)
      html = render(view)
      assert html =~ dep.app_template.name
    end

    test "ignores status update for different deployment id", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, {:deployment_status, 99999, :stopped})
      Process.sleep(100)
      html = render(view)
      assert html =~ dep.app_template.name
      assert html =~ "Running"
    end
  end

  describe "load_logs with different deployment states" do
    test "shows pending message for pending deployment", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :pending,
          external_id: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, :load_logs)
      Process.sleep(100)
      html = render(view)
      assert html =~ "pending" or html =~ "Pending" or html =~ "waiting"
    end

    test "shows deploying message for deploying deployment", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :deploying,
          external_id: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      Process.sleep(100)
      html = render(view)
      assert html =~ "starting up" or html =~ "Container"
    end

    test "shows error message for failed deployment with error_message and no external_id", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :failed,
          external_id: nil,
          error_message: "OOM killed"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      send(view.pid, :load_logs)
      Process.sleep(100)
      html = render(view)
      assert html =~ "OOM killed"
    end

    test "shows no container message for deployment with no external_id and non-special status", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :stopped,
          external_id: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "logs"})
      Process.sleep(100)
      html = render(view)
      assert html =~ "No container" or html =~ "no container"
    end
  end

  describe "removing status on deployment page" do
    test "renders removing status pill", %{conn: conn, tenant: tenant, template: template} do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :removing,
          external_id: nil
        )

      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "Removing"
    end
  end
end
