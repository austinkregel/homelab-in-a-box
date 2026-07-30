defmodule HomelabWeb.DeploymentNetnsTest do
  @moduledoc """
  Choosing which container's network a deployment uses, from the UI.

  The failure this guards against is that the setting was previously inexpressible
  anywhere but a compose file, and the compose importer dropped it — so an app meant to
  run behind a VPN could only be created outside it.
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

    tenant = insert(:tenant)

    donor =
      insert(:deployment,
        tenant: tenant,
        app_template:
          insert(:app_template,
            name: "Gluetun",
            slug: "gluetun",
            netns_donor_kind: "gluetun",
            ports: [],
            exposure_mode: :service
          ),
        domain: nil,
        status: :running,
        external_id: "gluetun-1"
      )

    app =
      insert(:deployment,
        tenant: tenant,
        app_template:
          insert(:app_template,
            name: "Sonarr",
            slug: "sonarr",
            ports: [%{"internal" => 8989, "role" => "web"}],
            exposure_mode: :public
          ),
        domain: "sonarr.example.com",
        status: :running,
        external_id: "sonarr-1"
      )

    %{tenant: tenant, donor: donor, app: app}
  end

  defp settings_form(conn, deployment) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})
    view
  end

  defp save(view, params) do
    defaults = %{
      "access" => "proxy",
      "auth" => "public",
      "domain" => "sonarr.example.com"
    }

    render_submit(view, "save_settings", %{"settings" => Map.merge(defaults, params)})
  end

  test "the control offers the other containers in the space", %{conn: conn, app: app} do
    view = settings_form(conn, app)
    html = render(view)

    assert html =~ "settings[network_parent_id]"
    assert html =~ "Through Gluetun"
  end

  test "picking a container routes this deployment through it", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    view = settings_form(conn, app)
    save(view, %{"network_parent_id" => to_string(donor.id)})

    assert Repo.reload!(app).network_parent_id == donor.id
  end

  test "the consequences are stated before saving, not discovered after", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    view = settings_form(conn, app)

    html =
      render_change(view, "settings_changed", %{
        "settings" => %{"network_parent_id" => to_string(donor.id)}
      })

    assert html =~ "no ports, no network aliases and no address of its own"
    assert html =~ "localhost"
  end

  test "host ports and host networking are disabled once a container is chosen", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    view = settings_form(conn, app)

    html =
      render_change(view, "settings_changed", %{
        "settings" => %{"network_parent_id" => to_string(donor.id)}
      })

    assert html =~ "Not available while routing through another container"
  end

  test "choosing 'its own network' clears the setting", %{conn: conn, app: app, donor: donor} do
    {:ok, app} = Deployments.update_deployment(app, %{network_parent_id: donor.id})

    view = settings_form(conn, app)
    save(view, %{"network_parent_id" => ""})

    assert Repo.reload!(app).network_parent_id == nil
  end

  test "the donor's page lists what shares its network, and the derived firewall rule", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    {:ok, _} = Deployments.update_deployment(app, %{network_parent_id: donor.id})

    {:ok, view, _html} = live(conn, ~p"/deployments/#{donor.id}")
    html = render_click(view, "switch_tab", %{"tab" => "settings"})

    assert html =~ "Sharing its network"
    assert html =~ "Sonarr"
    # Derived rather than typed — a 502 through Traefik is almost always this value
    # being wrong, and nothing in any log says so.
    assert html =~ "FIREWALL_INPUT_PORTS"
    assert html =~ "8989"
  end

  test "the child's page links back to the container carrying its traffic", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    {:ok, app} = Deployments.update_deployment(app, %{network_parent_id: donor.id})

    {:ok, view, _html} = live(conn, ~p"/deployments/#{app.id}")
    html = render_click(view, "switch_tab", %{"tab" => "settings"})

    assert html =~ "Through"
    assert html =~ ~p"/deployments/#{donor.id}"
  end

  test "a save that touches the group re-deploys the whole group", %{
    conn: conn,
    app: app,
    donor: donor
  } do
    # Re-creating the donor mints a new container id, and every other child is pinned to
    # the old one — so they have to go round together or they cannot start.
    view = settings_form(conn, app)
    save(view, %{"network_parent_id" => to_string(donor.id)})

    release = Repo.one!(Homelab.Deployments.Release) |> Repo.preload(:steps)

    assert release.deployment_id == donor.id
    assert Enum.any?(release.steps, &(&1.type == :netns_child_container))
  end

  test "a container already inside a namespace is not offered as a host", %{
    conn: conn,
    tenant: tenant,
    app: app,
    donor: donor
  } do
    # Chains are not supported: the staleness cascade becomes a graph walk.
    {:ok, _} = Deployments.update_deployment(app, %{network_parent_id: donor.id})

    other =
      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, name: "Radarr", slug: "radarr", ports: []),
        domain: "radarr.example.com"
      )

    html = settings_form(conn, other) |> render()

    assert html =~ "Through Gluetun"
    refute html =~ "Through Sonarr"
  end
end
