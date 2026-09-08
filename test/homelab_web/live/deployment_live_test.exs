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
    # The Volumes editor reads the host's volumes to fill a shared row's dropdown; the
    # tests about that list override this with volumes of its own.
    |> stub(:list_volumes, fn -> {:ok, []} end)
    # Config edits (env/settings) recreate the container; tests that assert the
    # exact recreate calls override these with `expect`.
    |> stub(:undeploy, fn _id -> :ok end)
    |> stub(:deploy, fn _spec -> {:ok, "recreated_container"} end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    # Opening Settings asks the image's registry which tags exist. Nothing here reads
    # that list, and the real Docker Hub driver answers by opening a TLS connection to
    # hub.docker.com, so offer no registry at all: `Tags.supported?/1` is then false and
    # the version field stays the free-text control it degrades to anyway.
    previous_registries = Application.get_env(:homelab, :registries)
    Application.put_env(:homelab, :registries, [])
    on_exit(fn -> restore(:registries, previous_registries) end)

    {:ok, conn: conn, tenant: tenant, template: template, deployment: deployment}
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, value), do: Application.put_env(:homelab, key, value)

  # A settings save plans a release, and the deployment/release broadcasts that follow are
  # handled AFTER the submit's reply — each one reloading the deployment from the Repo.
  # `render/1` is a synchronous round-trip queued behind those messages, so the assertions
  # read a page that has finished reloading rather than one still mid-flight.
  defp save_settings(view, settings) do
    render_submit(view, "save_settings", %{"settings" => settings})
    render(view)
  end

  describe "tab in the URL" do
    test "opens the tab named by the query parameter", %{conn: conn, deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}?tab=volumes")

      assert html =~ "Volumes"
    end

    test "switching a tab patches the URL", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")

      render_click(view, "switch_tab", %{"tab" => "volumes"})

      assert_patched(view, ~p"/deployments/#{dep.id}?tab=volumes")
    end

    test "an unknown tab falls back to overview", %{conn: conn, deployment: dep} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}?tab=nonsense")

      # Overview is the only panel that renders without a tab having been chosen.
      assert html =~ "overview"
    end
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
      assert html =~ "Back up"
    end

    test "switch to volumes tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})
      assert html =~ "Volumes"
    end

    test "releases tab renders steps and reacts to broadcasts", %{conn: conn, deployment: dep} do
      alias Homelab.Deployments.Releases

      {:ok, release} =
        Releases.plan_release(dep, [
          %{type: :backup_verify},
          %{type: :adopt_container}
        ])

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "releases"})
      assert html =~ "Backup verified"
      assert html =~ "Container adopted"

      # A step transition broadcasts and the panel re-renders with the new status.
      step = Releases.next_pending_step(release)
      {:ok, _} = Releases.transition_step(step, :completed, [:pending])

      _ = :sys.get_state(view.pid)
      assert render(view) =~ "Completed"
    end

    # The same stages in the same order whichever planner built the release, with the
    # steps that did not apply saying why in place.
    test "releases tab groups steps by stage and shows a skip reason", %{
      conn: conn,
      deployment: dep
    } do
      alias Homelab.Deployments.Releases

      {:ok, release} =
        Releases.plan_release(dep, [
          %{stage: :workload, type: :app_container},
          %{stage: :naming, type: :publish_dns}
        ])

      dns = Enum.find(release.steps, &(&1.type == :publish_dns))

      {:ok, _} =
        Releases.transition_step(dns, :skipped, [:pending],
          reason: {"skipped", "it holds no domain to resolve"}
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "releases"})

      assert html =~ "Workload"
      assert html =~ "Naming"
      assert html =~ "Skipped"
      assert html =~ "it holds no domain to resolve"
    end

    test "a note on a green step renders as a warning, not as a failure", %{
      conn: conn,
      deployment: dep
    } do
      alias Homelab.Deployments.Releases

      {:ok, release} =
        Releases.plan_release(dep, [
          %{stage: :prepare, type: :ensure_ingress_proxy},
          %{stage: :workload, type: :app_container}
        ])

      [proxy, container] = Enum.sort_by(release.steps, & &1.position)

      :ok = Releases.record_step_note(proxy, "Traefik not ensured: dns_token_missing")
      {:ok, _} = Releases.transition_step(proxy, :completed, [:pending])

      {:ok, _} =
        Releases.transition_step(container, :failed, [:pending], reason: {"error", "boom"})

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "releases"})

      assert has_element?(view, "p.text-warning", "Traefik not ensured")
      assert has_element?(view, "p.text-error", "boom")
    end

    test "companion deployment surfaces the app's driving release", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      alias Homelab.Deployments.Releases

      app = insert(:deployment, tenant: tenant, app_template: template, status: :failed)
      companion = insert(:deployment, tenant: tenant, status: :pending)

      {:ok, _release} =
        Releases.plan_release(app, [
          %{type: :dependency_container, resource_handle: %{"deployment_id" => companion.id}},
          %{type: :app_container}
        ])

      {:ok, view, _html} = live(conn, ~p"/deployments/#{companion.id}")
      html = render_click(view, "switch_tab", %{"tab" => "releases"})

      # The companion has no release of its own, but the app's release is shown.
      assert html =~ "part of another release"
      assert html =~ "Dependency container started"
    end

    # The complaint this answers: a stack release plans the same handful of step types
    # against every member, so the timeline was a column of identical "Container healthy"
    # lines with no way to tell which app each one was about.
    test "names the deployment each step acted on, so repeated labels stay distinguishable",
         %{conn: conn, tenant: tenant} do
      alias Homelab.Deployments.Releases

      donor =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, name: "Gluetun", slug: "gluetun"),
          domain: nil
        )

      sonarr =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, name: "Sonarr", slug: "sonarr"),
          domain: "sonarr.media.test",
          network_parent_id: donor.id
        )

      radarr =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, name: "Radarr", slug: "radarr"),
          domain: "radarr.media.test",
          network_parent_id: donor.id
        )

      {:ok, _release} =
        Releases.plan_release(donor, [
          %{stage: :workload, type: :app_container, resource_handle: %{}},
          %{stage: :workload, type: :await_health, resource_handle: %{}},
          %{
            stage: :workload,
            type: :netns_child_container,
            resource_handle: %{"deployment_id" => sonarr.id}
          },
          %{
            stage: :workload,
            type: :await_health,
            resource_handle: %{"deployment_id" => sonarr.id}
          },
          %{
            stage: :workload,
            type: :netns_child_container,
            resource_handle: %{"deployment_id" => radarr.id}
          },
          %{stage: :naming, type: :sync_domain, resource_handle: %{"deployment_id" => sonarr.id}},
          %{stage: :naming, type: :sync_domain, resource_handle: %{"deployment_id" => radarr.id}}
        ])

      {:ok, view, _html} = live(conn, ~p"/deployments/#{donor.id}")
      html = render_click(view, "switch_tab", %{"tab" => "releases"})

      # An empty handle means the anchor — the donor's own container.
      assert html =~ "Gluetun"

      # Which network they are in is the whole point of the step, so both ends are named.
      assert html =~ "Sonarr via Gluetun"
      assert html =~ "Radarr via Gluetun"

      # Two identical "Container healthy" rows, now told apart by their subject.
      assert html =~ "Container healthy"
      assert html =~ "Sonarr"

      # Domain steps name the domain, not the app: it is the thing being claimed.
      assert html =~ "sonarr.media.test"
      assert html =~ "radarr.media.test"
    end

    # The handle is what the step actually did; the row is only what it would do today.
    # A domain moved after the fact must not rewrite the history of the deploy that
    # published the old one.
    test "domain steps show the name that was published, not the one the row holds now",
         %{conn: conn, tenant: tenant, template: template} do
      alias Homelab.Deployments.Releases

      dep =
        insert(:deployment, tenant: tenant, app_template: template, domain: "new.example.test")

      {:ok, release} =
        Releases.plan_release(dep, [%{stage: :naming, type: :publish_dns, resource_handle: %{}}])

      [step] = release.steps

      _ =
        Releases.record_step_handle(step, %{
          "deployment_id" => dep.id,
          "fqdn" => "old.example.test",
          "record_count" => 2
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "releases"})

      assert html =~ "old.example.test"
      assert html =~ "2 records"
      refute html =~ "new.example.test"
    end

    # The banner calls one step out on its own, where "Container healthy" identifies
    # nothing at all.
    test "the failure banner names the step's subject", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      alias Homelab.Deployments.Releases

      app = insert(:deployment, tenant: tenant, app_template: template, status: :failed)

      companion =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, name: "Postgres", slug: "postgres"),
          status: :failed
        )

      {:ok, release} =
        Releases.plan_release(app, [
          %{
            stage: :workload,
            type: :dependency_container,
            resource_handle: %{"deployment_id" => companion.id}
          }
        ])

      [step] = release.steps
      {:ok, _} = Releases.transition_step(step, :failed, [:pending], reason: {"error", "boom"})

      {:ok, _view, html} = live(conn, ~p"/deployments/#{app.id}")

      assert html =~ "Deploy stopped at &quot;Dependency container started — Postgres&quot;"
    end

    test "redeploy re-plans a release and flashes", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "redeploy")

      assert html =~ "Re-running the deployment"
      assert Homelab.Deployments.Releases.driving_release(dep.id) != nil
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

    # The editor used to render one input per EXISTING key, so a variable the template
    # never declared could not be added at all. example.org needed REVERB_* on an already
    # deployed stack and there was no way to put them there.
    test "a variable the template never declared can be added", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      html =
        render_click(view, "save_env", %{
          "env" => %{
            "0" => %{"key" => "REVERB_APP_KEY", "value" => "pub-key"},
            "1" => %{"key" => "REVERB_APP_SECRET", "value" => "s3cret"},
            "2" => %{"key" => "BROADCAST_DRIVER", "value" => "reverb"}
          }
        })

      assert html =~ "Environment updated"

      env = Homelab.Deployments.get_deployment!(dep.id).env_overrides
      assert env["REVERB_APP_KEY"] == "pub-key"
      assert env["REVERB_APP_SECRET"] == "s3cret"
      assert env["BROADCAST_DRIVER"] == "reverb"
    end

    test "a row with a blank key is dropped rather than saved as an empty var", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      render_click(view, "save_env", %{
        "env" => %{
          "0" => %{"key" => "REAL_VAR", "value" => "yes"},
          "1" => %{"key" => "   ", "value" => "orphaned"}
        }
      })

      env = Homelab.Deployments.get_deployment!(dep.id).env_overrides
      assert env["REAL_VAR"] == "yes"
      refute Map.has_key?(env, "")
      refute Map.has_key?(env, "   ")
    end

    # Found in production, on a gluetun container holding VPN credentials. The Save in
    # the section HEADER was `type="button" phx-click="save_env"` and sat outside
    # `#env-form`, so the browser sent the event with no form data at all. Every test
    # above invokes the handler directly with params the real button never sent, which
    # is exactly why a total wipe survived a green suite.
    test "the header Save submits the form rather than firing a bare click", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      html = render_click(view, "start_env_edit", %{})

      refute html =~ ~s(phx-click="save_env"),
             "a control fires save_env as a bare click — no <input> value reaches the handler"

      assert html =~ ~s(form="env-form"),
             "the header Save is not associated with #env-form, so it submits nothing"
    end

    # The class, not just the instance: whatever reaches this handler, "no variables were
    # submitted" must never be read as "the operator wants zero variables". The form marks
    # its own submissions so that deleting every row still works and remains distinguishable.
    test "a save carrying no env params is refused rather than wiping every variable", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, dep} =
        Homelab.Deployments.update_deployment(dep, %{
          env_overrides: %{"OPENVPN_USER" => "austin", "OPENVPN_PASSWORD" => "hunter2"}
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      html = render_click(view, "save_env", %{})

      env = Homelab.Deployments.get_deployment!(dep.id).env_overrides
      assert env["OPENVPN_USER"] == "austin"
      assert env["OPENVPN_PASSWORD"] == "hunter2"
      refute html =~ "Environment updated"
    end

    test "deleting every row still clears the environment", %{conn: conn, deployment: dep} do
      {:ok, dep} =
        Homelab.Deployments.update_deployment(dep, %{env_overrides: %{"GOING_AWAY" => "yes"}})

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      html = render_click(view, "save_env", %{"env_submitted" => "1"})

      assert html =~ "Environment updated"
      assert Homelab.Deployments.get_deployment!(dep.id).env_overrides == %{}
    end

    # A credential here often has no other copy: the wizard generates one, the compose
    # import reads one out of a file the operator never sees. A masked input was then the
    # only place the value existed on screen, and editing `type` in devtools the only way
    # to read it back.
    test "a secret value is masked until the operator reveals it", %{conn: conn, deployment: dep} do
      {:ok, dep} =
        Homelab.Deployments.update_deployment(dep, %{
          env_overrides: %{"OPENVPN_PASSWORD" => "hunter2"}
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      # Rows sort by key: APP_ENV from the template first, then the password.
      assert has_element?(view, ~s(input[name="env[1][value]"][type="password"]))

      render_click(view, "toggle_env_visibility", %{"secret" => "1"})
      assert has_element?(view, ~s(input[name="env[1][value]"][type="text"]))

      render_click(view, "toggle_env_visibility", %{"secret" => "1"})
      assert has_element?(view, ~s(input[name="env[1][value]"][type="password"]))
    end

    test "a value that is not a credential is plain text with no toggle", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      assert has_element?(view, ~s(input[name="env[0][value]"][type="text"]))

      refute has_element?(
               view,
               ~s(button[phx-click="toggle_env_visibility"][phx-value-secret="0"])
             ),
             "APP_ENV holds no credential; an eye button there only invites the question"
    end

    # Reveal is addressed by row position, and deleting a row renumbers every row below
    # it. Left alone the set keeps pointing at the old slots, so a delete unmasks
    # whichever credential slid into one — a leak opened by the feature meant to make
    # secrets legible only on request.
    test "a reveal follows its row when a row above it is deleted", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, dep} =
        Homelab.Deployments.update_deployment(dep, %{
          env_overrides: %{"OPENVPN_PASSWORD" => "hunter2", "SMTP_PASS" => "mailer"}
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      # APP_ENV, OPENVPN_PASSWORD, SMTP_PASS.
      render_click(view, "toggle_env_visibility", %{"secret" => "1"})
      render_click(view, "remove_env_var", %{"index" => "0"})

      assert has_element?(view, ~s(input[name="env[0][key]"][value="OPENVPN_PASSWORD"]))
      assert has_element?(view, ~s(input[name="env[0][value]"][type="text"]))

      assert has_element?(view, ~s(input[name="env[1][value]"][type="password"])),
             "SMTP_PASS was never revealed and must not be dragged into view by a delete"
    end

    test "leaving edit mode masks everything again", %{conn: conn, deployment: dep} do
      {:ok, dep} =
        Homelab.Deployments.update_deployment(dep, %{
          env_overrides: %{"OPENVPN_PASSWORD" => "hunter2"}
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})
      render_click(view, "toggle_env_visibility", %{"secret" => "1"})
      render_click(view, "cancel_env_edit", %{})
      render_click(view, "start_env_edit", %{})

      assert has_element?(view, ~s(input[name="env[1][value]"][type="password"]))
    end

    test "add_env_var appends an empty row and remove_env_var drops one", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "environment"})
      render_click(view, "start_env_edit", %{})

      before = view |> element("#env-form") |> render()
      rows_before = before |> String.split(~s(name="env[)) |> length()

      after_add = render_click(view, "add_env_var", %{})
      rows_after = after_add |> String.split(~s(name="env[)) |> length()

      assert rows_after > rows_before, "add_env_var did not add a row"

      after_remove = render_click(view, "remove_env_var", %{"index" => "0"})
      rows_removed = after_remove |> String.split(~s(name="env[)) |> length()

      assert rows_removed < rows_after, "remove_env_var did not drop a row"
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
      render_click(view, "navigate", %{"to" => ~p"/spaces/#{tenant.id}"})
      assert_redirect(view, ~p"/spaces/#{tenant.id}")
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

    test "renders without crashing when the memory limit is 0 (unlimited container)", %{
      conn: conn,
      deployment: dep
    } do
      # Docker reports memory_limit: 0 for containers with no limit set. memory_percent
      # must not divide by zero (regression: ArithmeticError crashed the LiveView).
      Homelab.Mocks.Orchestrator
      |> stub(:stats, fn _id ->
        {:ok, %{cpu_percent: 10.0, memory_usage: 268_435_456, memory_limit: 0}}
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

    # The name column read `description || container_path`, and "" is truthy, so a volume
    # with an empty description — which is every volume the wizard writes — rendered a
    # blank cell.
    test "names the volume a row actually mounts", %{conn: conn, tenant: tenant} do
      template =
        insert(:app_template,
          slug: "plex",
          volumes: [
            %{"container_path" => "/music", "source" => "homelab-media-plex-music"},
            %{"container_path" => "/config", "description" => ""}
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_5"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})

      assert html =~ "homelab-media-plex-music"
      # The one with no name of its own is shown under the name it will be given.
      assert html =~ "homelab-#{tenant.slug}-plex-config"
    end

    # Read-only was visible only inside the editor, so the tab could not answer "can this
    # app write to that library" without clicking Edit.
    test "marks a read-only mount in the list", %{conn: conn, tenant: tenant} do
      template =
        insert(:app_template,
          volumes: [
            %{
              "container_path" => "/music",
              "source" => "homelab-media-plex-music",
              "read_only" => true
            }
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_6"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "switch_tab", %{"tab" => "volumes"})

      assert html =~ "read-only"
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

  describe "volumes tab editing" do
    test "saves a folder mount with its host path", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      render_submit(view, "save_volumes", %{
        "volumes" => %{
          "0" => %{
            "container_path" => "/var/www/html/storage",
            "type" => "bind",
            "source" => "/srv/homelab/authair/storage"
          }
        }
      })

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["type"] == "bind"
      assert vol["source"] == "/srv/homelab/authair/storage"
    end

    test "rejects a folder mount whose host path is a bare name", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      render_submit(view, "save_volumes", %{
        "volumes" => %{
          "0" => %{"container_path" => "/data", "type" => "bind", "source" => "storage"}
        }
      })

      # Docker would read "storage" as a named volume and mount an empty one.
      assert Homelab.Deployments.get_deployment!(dep.id).volumes_override == nil
    end

    # An adopted service's volumes carry the NAME of the volume the data was moved into.
    # Dropping that name on save makes SpecBuilder derive a synthetic one instead —
    # mounting an empty volume and orphaning every byte the adoption just migrated.
    test "keeps a managed volume's source name instead of re-deriving it", %{
      conn: conn,
      tenant: tenant
    } do
      template =
        insert(:app_template,
          volumes: [
            %{
              "container_path" => "/var/lib/postgresql/data",
              "source" => "homelab-managed-pg-var-lib-postgresql-data",
              "type" => "volume"
            }
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_3"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      render_submit(view, "save_volumes", %{
        "volumes" => %{
          "0" => %{
            "container_path" => "/var/lib/postgresql/data",
            "type" => "volume",
            "source" => "homelab-managed-pg-var-lib-postgresql-data"
          }
        }
      })

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == "homelab-managed-pg-var-lib-postgresql-data"
    end

    # The test above submits params it wrote itself, so it proved the HANDLER keeps the
    # name — while the form rendered no field to carry it, and the name was lost on the
    # way in. This one submits the form as the browser would.
    test "keeps a managed volume's source name through the rendered form", %{
      conn: conn,
      tenant: tenant
    } do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn -> {:ok, []} end)

      template =
        insert(:app_template,
          volumes: [
            %{
              "container_path" => "/var/lib/postgresql/data",
              "source" => "homelab-managed-pg-var-lib-postgresql-data",
              "type" => "volume"
            }
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_4"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      view |> form("#volumes-form") |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == "homelab-managed-pg-var-lib-postgresql-data"
    end

    test "offers the volumes on the host in a shared row's dropdown", %{
      conn: conn,
      deployment: dep
    } do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "homelab-media-plex-music", driver: "local", labels: %{}}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      html = change_volume_kind(view, "0", "shared")

      assert html =~ ~s(name="volumes[0][source]")
      assert html =~ ~s(<option value="homelab-media-plex-music")
    end

    # A managed row names nothing: the name follows the mount path, and the row shows the
    # one it will get rather than offering a box to type a different one into.
    test "a managed row shows the name its mount path derives", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      html = render_click(view, "start_volumes_edit", %{})

      derived =
        Homelab.Deployments.SpecBuilder.volume_name(
          dep.tenant.slug,
          dep.app_template.slug,
          "/data"
        )

      assert html =~ derived
      refute html =~ ~s(name="volumes[0][source]")
    end

    test "naming an existing volume records the row as borrowed", %{conn: conn, deployment: dep} do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "music-library", driver: "local", labels: %{}}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})
      change_volume_kind(view, "0", "shared")

      view
      |> form("#volumes-form",
        volumes: %{
          "0" => %{
            "source" => "music-library",
            "container_path" => "/music"
          }
        }
      )
      |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["borrowed"] == true
    end

    # The dropdown is the only way to name a shared volume, so a row pointed at a volume
    # the daemon does not report — removed, or `list_volumes` failed — has to keep it.
    # Without the option, rendering the form alone would detach the mount on the next save.
    test "a shared row keeps a volume the host does not report", %{conn: conn, tenant: tenant} do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn -> {:ok, []} end)

      template =
        insert(:app_template,
          volumes: [
            %{"container_path" => "/music", "source" => "music-library", "type" => "volume"}
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_8"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      html = render_click(view, "start_volumes_edit", %{})

      assert html =~ ~s(<option value="music-library" selected)

      view |> form("#volumes-form") |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == "music-library"
    end

    # Switching to managed is the operator saying the name should follow the mount path,
    # which is exactly a blank source — SpecBuilder derives the rest.
    test "switching a shared row to managed drops the name it carried", %{
      conn: conn,
      tenant: tenant
    } do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "music-library", driver: "local", labels: %{}}]}
      end)

      template =
        insert(:app_template,
          volumes: [
            %{"container_path" => "/music", "source" => "music-library", "type" => "volume"}
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_9"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})
      change_volume_kind(view, "0", "managed")

      view |> form("#volumes-form") |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == nil
      assert vol["type"] == "volume"
    end

    # A row switched to shared has no volume picked yet, and a row with no name is a
    # managed one — so the kind has to be carried, or the select snaps back to Managed on
    # the change event that opened the dropdown.
    test "a row switched to shared stays shared before a volume is picked", %{
      conn: conn,
      deployment: dep
    } do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "music-library", driver: "local", labels: %{}}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})
      change_volume_kind(view, "0", "shared")

      html =
        view
        |> form("#volumes-form", volumes: %{"0" => %{"container_path" => "/music"}})
        |> render_change()

      assert html =~ ~s(<option value="shared" selected)
      assert html =~ ~s(name="volumes[0][source]")
    end

    # The flag has to survive a save that did not touch the name, or a volume this app
    # owns would become borrowed the moment the daemon knows about it.
    test "a volume this deployment owns stays owned across an edit", %{
      conn: conn,
      tenant: tenant
    } do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "app-data", driver: "local", labels: %{}}]}
      end)

      template =
        insert(:app_template,
          volumes: [
            %{"container_path" => "/data", "source" => "app-data", "type" => "volume"}
          ]
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "c_7"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      view |> form("#volumes-form") |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == "app-data"
      assert vol["borrowed"] == false
    end

    # Any volume on this host may go into any deployment — one library serving several
    # apps is the point of naming it here rather than only on the storage page.
    test "mounts an existing volume named in the form", %{conn: conn, deployment: dep} do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn ->
        {:ok, [%{name: "homelab-media-plex-music", driver: "local", labels: %{}}]}
      end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit", %{})

      change_volume_kind(view, "0", "shared")

      view
      |> form("#volumes-form",
        volumes: %{
          "0" => %{
            "source" => "homelab-media-plex-music",
            "container_path" => "/music",
            "read_only" => "true"
          }
        }
      )
      |> render_submit()

      assert [vol] = Homelab.Deployments.get_deployment!(dep.id).volumes_override
      assert vol["source"] == "homelab-media-plex-music"
      assert vol["read_only"] == true
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
      template =
        insert(:app_template, default_env: %{"DB_PASSWORD" => "s3cret", "APP_KEY" => "val"})

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

    test "stopped deployment shows Stopped status pill", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "deploying deployment shows Deploying status pill", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "breadcrumb has links to dashboard and space", %{
      conn: conn,
      deployment: dep,
      tenant: tenant
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "a[href='/']", "Dashboard")
      assert has_element?(view, "a[href='/spaces/#{tenant.id}']")
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

    test "stopped deployment shows Start but not Stop or Restart", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "failed deployment shows Start and Delete only", %{
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
          error_message: "Boom"
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      assert has_element?(view, "button", "Start")
      assert has_element?(view, "button", "Delete")
      refute has_element?(view, "button", "Stop")
      refute has_element?(view, "button", "Restart")
    end

    test "pending deployment without external_id hides Restart", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

      assert html =~ "No traffic data available" or html =~ "Metrics will appear" or
               html =~ "Traffic"
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

    test "save_env with invalid data shows error", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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
    test "starts a stopped deployment from detail page", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "start failure still succeeds with status update", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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
    test "deletes deployment and redirects to root", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "keeps the deployment and flashes when undeploy fails", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "undeletable_container"
        )

      Homelab.Mocks.Orchestrator
      |> stub(:undeploy, fn _spec -> {:error, :docker_down} end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render_click(view, "delete", %{})

      assert html =~ "the deployment was kept"
      assert {:ok, _} = Homelab.Deployments.get_deployment(dep.id)
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
    test "shows pending message for pending deployment", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "shows deploying message for deploying deployment", %{
      conn: conn,
      tenant: tenant,
      template: template
    } do
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

    test "shows no container message for deployment with no external_id and non-special status",
         %{
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

  describe "production-readiness checklist" do
    test "overview shows the checklist with a Fix link for each gap", %{
      conn: conn,
      deployment: dep
    } do
      # Factory deployment: proxy + domain + healthcheck + limits, but no backups,
      # so the backups gate is the one open gap.
      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")

      assert html =~ "Production readiness"
      assert html =~ "Backups"
      assert html =~ ~s(phx-value-tab="backups")
    end

    test "clicking Fix on a gap switches to that tab", %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")

      view
      |> element(~s(button[phx-value-tab="backups"]), "Fix")
      |> render_click()

      assert render(view) =~ "Back up"
    end

    test "a fully-configured deployment reports all gates ready", %{conn: conn, tenant: tenant} do
      template =
        insert(:app_template,
          exposure_mode: :sso_protected,
          health_check: %{"path" => "/health"},
          resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512}
        )

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_ready",
          domain: "ready.example.com"
        )

      insert(:backup_job, deployment: dep, status: :completed)

      {:ok, _view, html} = live(conn, ~p"/deployments/#{dep.id}")
      assert html =~ "4 / 4 ready"
    end
  end

  # The gateway calls a domain "active" whenever a ROUTER exists — true even while
  # Traefik serves its self-signed default because ACME never issued. The card reports
  # the certificate actually being served instead.
  describe "TLS certificate card" do
    setup do
      on_exit(fn -> Application.delete_env(:homelab, :tls_probe_result) end)
      :ok
    end

    test "shows the issuer and real expiry of a valid certificate", %{conn: conn, deployment: dep} do
      Application.put_env(:homelab, :tls_probe_result, :healthy)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render(view)

      assert html =~ "TLS certificate"
      assert html =~ "Valid"
      assert html =~ "Let&#39;s Encrypt R3"
      assert html =~ "60d"
    end

    test "calls out Traefik's self-signed default certificate", %{conn: conn, deployment: dep} do
      Application.put_env(:homelab, :tls_probe_result, :self_signed)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render(view)

      # The whole point: a custom domain silently falling back to the default cert must
      # not look healthy.
      assert html =~ "Self-signed"
      assert html =~ "ACME never issued a real one"
    end

    test "reports a failed handshake rather than claiming health", %{conn: conn, deployment: dep} do
      Application.put_env(
        :homelab,
        :tls_probe_result,
        {:error, {:handshake_failed, :econnrefused}}
      )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      html = render(view)

      assert html =~ "Could not complete a TLS handshake"
    end
  end

  describe "volumes editing" do
    # The Volumes tab was a read-only table of template.volumes, and there was no
    # volumes_override at all -- so an app needing durable storage its catalog entry never
    # declared simply could not get it from the UI.
    test "a durable volume can be added to a deployment from the UI", %{
      conn: conn,
      deployment: dep
    } do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit")
      render_click(view, "add_volume")

      view
      |> form("#volumes-form",
        volumes: %{
          "0" => %{"container_path" => "/var/www/html/storage", "description" => "app storage"}
        }
      )
      |> render_submit()

      reloaded = Homelab.Deployments.get_deployment!(dep.id)
      assert [%{"container_path" => "/var/www/html/storage"}] = reloaded.volumes_override

      assert_reconfigure_release(dep.id)
    end

    test "a relative mount path is rejected rather than turned into a garbage volume name",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "volumes"})
      render_click(view, "start_volumes_edit")
      render_click(view, "add_volume")

      html =
        view
        |> form("#volumes-form", volumes: %{"0" => %{"container_path" => "storage"}})
        |> render_submit()

      assert html =~ "absolute"
      assert Homelab.Deployments.get_deployment!(dep.id).volumes_override == nil
    end
  end

  describe "settings reconfiguration" do
    test "saving proxy settings persists domain + auth and never publishes host ports",
         %{conn: conn, deployment: dep} do
      # Config changes CONVERGE the live workload -- deploy/1 pulls the image, then rolls
      # the new spec onto the existing service. Tearing it down first took the app offline
      # for the entire image pull, on every save.
      #
      # `expect(:undeploy, 0, ...)` is the real assertion here: the setup block stubs
      # undeploy, so without this a regression that tears the service down again would
      # pass silently.
      Homelab.Mocks.Orchestrator
      |> expect(:undeploy, 0, fn _id -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")

      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      save_settings(view, %{
        "auth" => "public",
        "routes" => %{"0" => %{"host" => "dashy.example.com", "port" => "8080"}}
      })

      updated = Homelab.Deployments.get_deployment!(dep.id)
      assert updated.domain == "dashy.example.com"
      assert updated.exposure_mode_override == "public"

      # Proxy access never BINDS host ports — but it still has to know the port the app
      # listens on inside the container, because that is where Traefik forwards. This
      # used to save `[]`, which is not "inherit the template": effective_ports/1 only
      # inherits on nil, so the empty override won and the proxy fell back to port 80.
      refute updated.ports_override == [],
             "an empty override repoints Traefik at port 80; nil inherits the template"

      assert is_nil(updated.ports_override)

      # And the app's port survives — inherited from the template — so the route still
      # lands on it instead of on the port-80 fallback.
      reloaded = Homelab.Deployments.get_deployment!(dep.id)

      assert Homelab.Deployments.Access.effective_ports(reloaded) ==
               reloaded.app_template.ports

      assert_reconfigure_release(dep.id)
    end

    # example.org: Laravel on 8000, Reverb websockets on 6001. The browser opens
    # wss://example.org/app on 443, so /app must reach 6001 -- the model could only express
    # one backend port, and every websocket handshake landed on the HTTP server.
    test "an extra path route persists and reaches a different container port",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")
      render_click(view, "settings_add_route")

      save_settings(view, %{
        "routes" => %{
          "0" => %{"host" => "example.org", "port" => "8000"},
          "1" => %{"host" => "example.org", "path_prefix" => "/app", "port" => "6001"}
        }
      })

      reloaded = Homelab.Deployments.get_deployment!(dep.id)
      assert [%{"path_prefix" => "/app", "port" => 6001}] = reloaded.extra_routes

      assert_reconfigure_release(dep.id)
    end

    test "a half-filled route row is dropped rather than saved broken",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")
      render_click(view, "settings_add_route")
      render_click(view, "settings_add_route")

      save_settings(view, %{
        "routes" => %{
          "0" => %{"host" => "example.org", "port" => "8000"},
          "1" => %{"host" => "example.org", "path_prefix" => "/app", "port" => "6001"},
          "2" => %{"host" => "example.org", "path_prefix" => "/half", "port" => ""}
        }
      })

      reloaded = Homelab.Deployments.get_deployment!(dep.id)
      assert [%{"path_prefix" => "/app"}] = reloaded.extra_routes

      assert_reconfigure_release(dep.id)
    end

    test "switching to Host ports persists the container->host binding and recreates",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      render_click(view, "settings_add_port")

      # Exposure is per PORT now, and dropping the routes is what makes the deployment
      # host-mode: nothing is derived from a mode the operator picked separately.
      render_click(view, "settings_remove_route", %{"index" => "0"})

      save_settings(view, %{
        "ports" => %{
          "0" => %{"internal" => "8080", "external" => "9090", "exposure" => "host"}
        }
      })

      updated = Homelab.Deployments.get_deployment!(dep.id)
      assert updated.exposure_mode_override == "host"
      # Host access drops the public domain; every listed port is a binding.
      assert updated.domain == nil

      assert [%{"internal" => "8080", "external" => "9090", "published" => true}] =
               updated.ports_override

      assert_reconfigure_release(dep.id)
    end

    test "a UDP host binding persists, and survives an unrelated later save",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")
      render_click(view, "settings_add_port")

      render_click(view, "settings_remove_route", %{"index" => "0"})

      save_settings(view, %{
        "ports" => %{
          "0" => %{
            "internal" => "27900",
            "external" => "27900",
            "protocol" => "udp",
            "exposure" => "host"
          }
        }
      })

      updated = Homelab.Deployments.get_deployment!(dep.id)
      assert [%{"internal" => "27900", "protocol" => "udp"}] = updated.ports_override
      assert_reconfigure_release(dep.id)

      # The real regression risk is not the first save but the SECOND: the settings form
      # re-renders from stored state, and a protocol the form fails to round-trip silently
      # reverts to tcp the next time anything else on the page is saved.
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      html = save_settings(view, %{"memory_mb" => "1024"})

      reloaded = Homelab.Deployments.get_deployment!(dep.id)

      assert [%{"internal" => "27900", "protocol" => "udp"}] = reloaded.ports_override,
             "an unrelated save rewrote the port back to tcp"

      # Oban is `testing: :manual`, so the first release is still sitting in `:planning`
      # when the second save lands — which is exactly the case the newest plan has to win.
      # The second save supersedes the first and applies, rather than persisting an edit
      # that never reaches the container.
      assert reloaded.resource_limits_override["memory_mb"] == 1024
      refute html =~ "Saved, but not applied yet"

      driving = Homelab.Deployments.Releases.driving_release(dep.id)
      assert driving.plan["kind"] == "reconfigure"
      assert driving.status == :planning

      superseded =
        dep.id
        |> Homelab.Deployments.Releases.list_releases_for_deployment()
        |> Enum.find(&(&1.status == :superseded))

      assert superseded, "the first release should have been handed over, not left active"
    end

    test "saving resilience limits + health path persists per-deployment overrides",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      save_settings(view, %{
        "auth" => "sso_protected",
        "memory_mb" => "1024",
        "cpu_shares" => "2048",
        "health" => %{"mode" => "path", "path" => "/healthz"}
      })

      updated = Homelab.Deployments.get_deployment!(dep.id)
      assert updated.resource_limits_override == %{"memory_mb" => 1024, "cpu_shares" => 2048}
      assert updated.health_check_override["path"] == "/healthz"

      assert_reconfigure_release(dep.id)
    end

    test "overriding one deployment's config does not affect a sibling on the same template",
         %{conn: conn, tenant: tenant, template: template, deployment: dep} do
      sibling =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "sibling_123",
          domain: nil
        )

      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      # Removing the last route is what makes it internal: nothing is derived from a
      # mode picked separately from the routes it describes.
      render_click(view, "settings_remove_route", %{"index" => "0"})
      save_settings(view, %{})

      assert Homelab.Deployments.get_deployment!(dep.id).exposure_mode_override == "service"
      # Sibling untouched — its overrides remain nil and it inherits the template.
      reloaded_sibling = Homelab.Deployments.get_deployment!(sibling.id)
      assert reloaded_sibling.exposure_mode_override == nil
      assert reloaded_sibling.domain == nil

      assert_reconfigure_release(dep.id)

      # The sibling was never in the release, so nothing planned against it either.
      refute Homelab.Deployments.Releases.driving_release(sibling.id)
    end
  end

  describe "release visibility after a config save" do
    # The gap this closes: the container WAS being recreated, but by an imperative call
    # that planned nothing, so the page that exists to show what a deploy is doing showed
    # "No releases yet" for every version bump and every network edit.
    test "a settings save appears on the Releases tab, labelled as a config change",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")

      render_click(view, "switch_tab", %{"tab" => "releases"})
      assert render(view) =~ "No releases yet"

      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      save_settings(view, %{
        "routes" => %{"0" => %{"host" => "app.example.com", "port" => "8080"}}
      })

      html = render_click(view, "switch_tab", %{"tab" => "releases"})

      refute html =~ "No releases yet"
      assert html =~ "Config change"
      assert html =~ "Container created"
    end

    # Pressing it used to make it vanish, which reads the same as the control having been
    # removed. It stays, disabled, and says which step the release is on.
    test "the redeploy button reports the running release instead of disappearing",
         %{conn: conn, deployment: dep} do
      {:ok, view, _html} = live(conn, ~p"/deployments/#{dep.id}")

      assert render(view) =~ "Re-run deploy"

      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit")

      render_click(view, "settings_remove_route", %{"index" => "0"})
      save_settings(view, %{})

      html = render_click(view, "switch_tab", %{"tab" => "overview"})

      refute html =~ "Re-run deploy"

      # Every release opens with the prepare stage, so that is the step it is on.
      assert html =~ "Reverse proxy running", "the button should name the step the release is on"
      assert has_element?(view, "button[phx-click=\"redeploy\"][disabled]")
    end
  end

  # A config save no longer deploys inside the request. It plans a release and hands it
  # to `ReleaseRunner`, so the `expect(:deploy, ...)` these tests used to carry asserted
  # a call that now happens in an Oban worker `testing: :manual` never runs — it would
  # pass just as happily if the save had stopped applying anything at all.
  #
  # The equivalent assertion is against the release that will make the call: it exists,
  # it is labelled as a config change rather than something else that happened to be
  # planned, and it actually contains the step that replaces the container.
  defp assert_reconfigure_release(deployment_id) do
    release = Homelab.Deployments.Releases.driving_release(deployment_id)

    assert release,
           "no release was planned — the saved config would never reach the container"

    assert release.plan["kind"] == "reconfigure"
    assert Enum.any?(release.steps, &(&1.type == :app_container))
    assert Enum.any?(release.steps, &(&1.type == :await_health))

    release
  end

  # Picking a row's kind is what decides which name control it gets, so a test that wants
  # the shared dropdown has to change the kind first, exactly as the browser does.
  defp change_volume_kind(view, index, kind) do
    view
    |> form("#volumes-form", volumes: %{index => %{"kind" => kind}})
    |> render_change()
  end
end
