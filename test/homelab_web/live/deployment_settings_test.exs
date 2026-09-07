defmodule HomelabWeb.DeploymentSettingsTest do
  @moduledoc """
  The Settings tab as one editor rather than three forms.

  The behaviours here are the ones the split could not have: a summary that reads the
  whole configuration back, a dirty count across every card, a diff before the container
  is recreated, and warnings that say which of them the operator has to act on.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Deployments
  alias Homelab.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:undeploy, fn _id -> :ok end)
    |> stub(:publish, fn _, _ -> :ok end)
    |> stub(:unpublish, fn _, _ -> :ok end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    git =
      insert(:deployment,
        tenant: insert(:tenant),
        app_template:
          insert(:app_template,
            name: "Forgejo",
            slug: "forgejo",
            ports: [
              %{"internal" => 3000, "role" => "web"},
              %{"internal" => 22, "role" => "other"}
            ],
            exposure_mode: :public
          ),
        domain: "git.kregel.dev",
        routed_port: 3000,
        ports_override: [
          %{"internal" => "3000", "role" => "web", "protocol" => "tcp"},
          %{
            "internal" => "22",
            "external" => "2222",
            "role" => "other",
            "protocol" => "tcp",
            "published" => true
          }
        ],
        status: :running,
        external_id: "forgejo-1"
      )

    %{git: git}
  end

  defp open(conn, deployment) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    view
  end

  defp editing(conn, deployment) do
    view = open(conn, deployment)
    render_click(view, "start_settings_edit", %{})
    view
  end

  describe "viewing" do
    # The old read-only view rendered three rows -- access, domain, ports -- which is why
    # every screenshot of this page was taken in edit mode.
    test "the whole configuration is readable without opening the editor", %{
      conn: conn,
      git: git
    } do
      html = open(conn, git) |> render()

      assert html =~ "How it&#39;s reached"
      assert html =~ "git.kregel.dev"
      assert html =~ "Version"
      assert html =~ "Runtime"
      assert html =~ "Resources"
      # The SSH binding, stated as the binding it actually is.
      assert html =~ "0.0.0.0:2222"
    end

    test "the summary states each route and each host binding as a sentence", %{
      conn: conn,
      git: git
    } do
      html = open(conn, git) |> render()

      assert html =~ "https://git.kregel.dev"
      assert html =~ "Published"
      assert html =~ "Reverse proxy"
    end

    test "a deployment reachable from nowhere says so plainly", %{conn: conn, git: git} do
      {:ok, internal} =
        Deployments.update_deployment(git, %{
          domain: nil,
          exposure_mode_override: "service",
          ports_override: [%{"internal" => "5432", "protocol" => "tcp", "role" => "db"}]
        })

      html = open(conn, internal) |> render()

      assert html =~ "Not reachable from anywhere"
    end
  end

  describe "one save across every card" do
    test "the bar counts changes from different cards together", %{conn: conn, git: git} do
      view = editing(conn, git)

      html =
        render_change(view, "settings_changed", %{
          "settings" => %{"image" => "forgejo/forgejo:9", "memory_mb" => "2048"}
        })

      assert html =~ "2 changes"
      assert html =~ "recreates the container"
    end

    test "an untouched editor offers nothing to save", %{conn: conn, git: git} do
      html = editing(conn, git) |> render()

      refute html =~ "Review &amp; recreate"
    end

    test "discarding returns every card to what is stored", %{conn: conn, git: git} do
      view = editing(conn, git)

      render_change(view, "settings_changed", %{"settings" => %{"memory_mb" => "2048"}})
      html = render_click(view, "settings_discard", %{})

      refute html =~ "1 change"
    end

    test "the review sheet lists the before and after, including the derived mode", %{
      conn: conn,
      git: git
    } do
      view = editing(conn, git)

      # Drop the route: the container stops being proxied, which nothing on the page
      # asked for directly.
      render_click(view, "settings_remove_route", %{"index" => "0"})
      html = render_click(view, "settings_review", %{})

      assert html =~ "Recreate Forgejo?"
      assert html =~ "exposure_mode (derived)"
      assert html =~ "host"
    end

    test "confirming from the sheet saves what the assigns hold", %{conn: conn, git: git} do
      view = editing(conn, git)

      render_change(view, "settings_changed", %{"settings" => %{"memory_mb" => "2048"}})
      render_click(view, "settings_review", %{})
      # The sheet's button posts no form payload of its own.
      render_click(view, "save_settings", %{})

      assert Repo.reload!(git).resource_limits_override["memory_mb"] == 2048
    end
  end

  describe "findings carry a severity" do
    test "a UDP port set to proxied is reported as breaking at runtime", %{
      conn: conn,
      git: git
    } do
      view = editing(conn, git)

      html =
        render_change(view, "settings_changed", %{
          "settings" => %{
            "ports" => %{
              "0" => %{"internal" => "3000", "protocol" => "udp", "exposure" => "proxy"}
            }
          }
        })

      assert html =~ "UDP cannot be proxied"
    end

    test "replicas that cannot bind their ports are reported as a refusal", %{
      conn: conn,
      git: git
    } do
      view = editing(conn, git)
      html = render_change(view, "settings_changed", %{"settings" => %{"replicas" => "3"}})

      assert html =~ "Replicas cannot bind host ports"
    end

    test "a proxied port with no route pointing at it is called out", %{conn: conn, git: git} do
      view = editing(conn, git)
      render_click(view, "settings_remove_route", %{"index" => "0"})
      html = render(view)

      assert html =~ "no route points here yet" or html =~ "Nothing routes here"
    end
  end

  describe "the health check is a Docker Test array" do
    test "the emitted array is shown, not just the path", %{conn: conn, git: git} do
      view = editing(conn, git)

      html =
        render_change(view, "settings_changed", %{
          "settings" => %{"health" => %{"mode" => "path", "path" => "/api/healthz"}}
        })

      assert html =~ "Emits"
      assert html =~ "CMD-SHELL"
      assert html =~ "localhost:3000/api/healthz"
    end

    test "a shell command persists as a command, not as an HTTP probe", %{conn: conn, git: git} do
      view = editing(conn, git)

      render_submit(view, "save_settings", %{
        "settings" => %{
          "health" => %{
            "mode" => "command",
            "shell" => "true",
            "command" => "/usr/bin/forgejo doctor",
            "interval" => "15"
          }
        }
      })

      reloaded = Repo.reload!(git)
      assert reloaded.health_check_override["command"] == "/usr/bin/forgejo doctor"
      assert reloaded.health_check_override["interval"] == 15
      refute Map.has_key?(reloaded.health_check_override, "path")
    end

    test "an exec check persists as a raw Test array, with no shell in the way", %{
      conn: conn,
      git: git
    } do
      view = editing(conn, git)

      render_submit(view, "save_settings", %{
        "settings" => %{
          "health" => %{
            "mode" => "command",
            "shell" => "false",
            "args" => %{"0" => "/usr/bin/healthcheck", "1" => "--quiet"}
          }
        }
      })

      assert Repo.reload!(git).health_check_override["test"] ==
               ["CMD", "/usr/bin/healthcheck", "--quiet"]
    end

    test "choosing None stores an explicit no-check rather than inheriting one", %{
      conn: conn,
      git: git
    } do
      view = editing(conn, git)

      render_submit(view, "save_settings", %{"settings" => %{"health" => %{"mode" => "none"}}})

      reloaded = Repo.reload!(git)
      assert reloaded.health_check_override == %{}

      refute Homelab.Deployments.SpecBuilder.declares_healthcheck?(
               Homelab.Deployments.Access.effective_health_check(reloaded)
             )
    end

    test "an adopted command check survives being looked at", %{conn: conn, git: git} do
      # AdoptionDiscovery captures the original container's check verbatim. The old page
      # read only `path`, so opening Settings displayed "no check" and saving replaced a
      # working probe with an HTTP one against a port the container does not serve.
      {:ok, adopted} =
        Deployments.update_deployment(git, %{
          health_check_override: %{
            "test" => ["CMD-SHELL", "/gluetun-entrypoint healthcheck"],
            "interval" => 5
          }
        })

      view = editing(conn, adopted)
      html = render(view)

      assert html =~ "/gluetun-entrypoint healthcheck"

      render_submit(view, "save_settings", %{"settings" => %{}})

      assert Repo.reload!(git).health_check_override["command"] ==
               "/gluetun-entrypoint healthcheck"
    end
  end

  describe "kernel privileges list every option" do
    test "the capability list is rendered with the ones that are on marked", %{
      conn: conn,
      git: git
    } do
      {:ok, privileged} =
        Deployments.update_deployment(git, %{capabilities_add_override: ["NET_ADMIN"]})

      view = editing(conn, privileged)
      html = render(view)

      # Every option, not a free-text box.
      assert html =~ "SYS_PTRACE"
      assert html =~ "CHOWN"

      assert has_element?(
               view,
               ~s(input[name="settings[caps_add][]"][value="NET_ADMIN"][checked])
             )

      refute has_element?(view, ~s(input[name="settings[caps_add][]"][value="CHOWN"][checked]))
    end
  end
end
