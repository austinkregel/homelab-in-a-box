defmodule HomelabWeb.DeploymentBackendSchemeTest do
  @moduledoc """
  Telling Traefik that the container behind a route speaks TLS.

  An app that terminates TLS itself — code-server, a Unifi controller, anything started
  with a `--cert` flag — answers the proxy's plaintext request with `400 Bad Request`.
  Nothing about that is legible from the outside: the route is up, the routed port is
  right, the container reports healthy, and the browser gets a 400 that belongs to
  neither the proxy nor, obviously, the app.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Deployments
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Infrastructure
  alias Homelab.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:undeploy, fn _id -> :ok end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    code =
      insert(:deployment,
        tenant: insert(:tenant),
        app_template:
          insert(:app_template,
            name: "code-server",
            slug: "code-server",
            ports: [%{"internal" => 8443, "role" => "web"}],
            exposure_mode: :public
          ),
        domain: "code.example.com",
        routed_port: 8443,
        status: :running,
        external_id: "code-1"
      )

    %{code: code}
  end

  defp save(conn, app, settings) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{app.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    defaults = %{
      "access" => "proxy",
      "auth" => "public",
      "domain" => app.domain,
      "routed_port" => to_string(app.routed_port)
    }

    html = render_submit(view, "save_settings", %{"settings" => Map.merge(defaults, settings)})

    {Repo.get!(Deployments.Deployment, app.id) |> Repo.preload([:tenant, :app_template]), html}
  end

  test "choosing HTTPS reaches the labels the proxy actually reads", %{conn: conn, code: code} do
    {updated, _html} = save(conn, code, %{"backend_scheme" => "https"})

    assert updated.proxy_options["backend_scheme"] == "https"

    # Asserting on the saved row alone would pass with the label side never wired up,
    # which is the half that fixes the 400.
    assert {:ok, spec} = SpecBuilder.build(updated)

    assert spec.labels["traefik.http.services.code-example-com.loadbalancer.server.scheme"] ==
             "https"

    # And the second half: without a transport that skips verification, the 400 becomes a
    # 500 — the backend's certificate is self-signed and names something other than the
    # container Traefik dialled.
    assert spec.labels["traefik.http.services.code-example-com.loadbalancer.serverstransport"] ==
             Infrastructure.internal_tls_transport()
  end

  test "the default is plaintext, and it adds no labels", %{conn: conn, code: code} do
    {updated, _html} = save(conn, code, %{})

    assert SpecBuilder.backend_scheme(updated) == "http"
    assert {:ok, spec} = SpecBuilder.build(updated)

    assert spec.labels["traefik.http.services.code-example-com.loadbalancer.server.port"] ==
             "8443"

    refute Map.has_key?(
             spec.labels,
             "traefik.http.services.code-example-com.loadbalancer.server.scheme"
           )
  end

  # Every other field on this form round-trips through assigns; one that recomputed
  # `selected` from the persisted deployment on each render would revert the operator's
  # pick on the next keystroke and save the old value — the bug `settings_routed_port`
  # already carries a comment about.
  test "a chosen scheme survives the next change event", %{conn: conn, code: code} do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{code.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    render_change(view, "settings_changed", %{
      "settings" => %{"backend_scheme" => "https", "domain" => "code.example.com"}
    })

    render_change(view, "settings_changed", %{
      "settings" => %{"domain" => "code.example.com"}
    })

    assert view |> element(~s(#settings-backend-scheme option[value="https"])) |> render() =~
             "selected"

    refute view |> element(~s(#settings-backend-scheme option[value="http"])) |> render() =~
             "selected"
  end

  test "reopening the form shows the scheme the deployment is running with", %{
    conn: conn,
    code: code
  } do
    {:ok, code} =
      Deployments.update_deployment(code, %{proxy_options: %{"backend_scheme" => "https"}})

    {:ok, view, _html} = live(conn, ~p"/deployments/#{code.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    assert view |> element(~s(#settings-backend-scheme option[value="https"])) |> render() =~
             "selected"

    refute view |> element(~s(#settings-backend-scheme option[value="http"])) |> render() =~
             "selected"
  end

  # `SpecBuilder.backend_scheme/1` matches on "https" and treats everything else as
  # plaintext, so a typo would produce the exact 400 this setting exists to fix while the
  # settings page showed it as saved.
  test "a scheme the builder does not understand is rejected at the changeset", %{code: code} do
    assert {:error, changeset} =
             Deployments.update_deployment(code, %{proxy_options: %{"backend_scheme" => "ssl"}})

    assert Keyword.has_key?(changeset.errors, :proxy_options)
  end
end
