defmodule HomelabWeb.DeployWizardComposeRuntimeTest do
  @moduledoc """
  What survives a docker-compose import.

  Two separate leaks met here. The parser read only image/ports/volumes/environment/
  depends_on, so a service's `cap_add`, `devices`, `sysctls`, `restart` and `command`
  were dropped without a word — importing a VPN stack produced templates that looked
  complete and containers that could not work. And `advanced_attrs/1` was merged into
  the plain `"deploy"` handler but not into `"deploy_compose"`, so the Advanced panel
  the operator had just filled in was discarded while still showing its values.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Catalog.AppTemplate
  alias Homelab.Deployments.Deployment
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

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    %{tenant: insert(:tenant)}
  end

  @gluetun_compose """
  services:
    gluetun:
      image: qmcgaw/gluetun:latest
      cap_add:
        - NET_ADMIN
      devices:
        - /dev/net/tun:/dev/net/tun
      sysctls:
        - net.ipv4.conf.all.src_valid_mark=1
      restart: unless-stopped
      environment:
        - VPN_SERVICE_PROVIDER=mullvad
  """

  defp import_compose(conn, tenant, yaml, advanced \\ %{}, domain \\ "") do
    {:ok, view, _html} = live(conn, ~p"/deploy/new?step=app&type=compose")

    view
    |> form("form[phx-submit=parse_compose]", %{"compose_yaml" => yaml})
    |> render_submit()

    if advanced != %{}, do: render_change(view, "advanced_changed", %{"advanced" => advanced})

    render_click(view, "deploy_compose", %{
      "tenant_id" => to_string(tenant.id),
      "exposure_mode" => "service",
      "domain" => domain
    })

    view
  end

  defp imported_template(slug), do: Repo.get_by!(AppTemplate, slug: slug)

  defp imported_deployment(slug) do
    Repo.get_by!(Deployment, app_template_id: imported_template(slug).id)
  end

  test "capabilities, devices and sysctls survive the import", %{conn: conn, tenant: tenant} do
    import_compose(conn, tenant, @gluetun_compose)

    template = imported_template("gluetun")

    assert template.capabilities_add == ["NET_ADMIN"]

    assert [%{"host_path" => "/dev/net/tun", "container_path" => "/dev/net/tun"}] =
             template.devices

    assert template.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
  end

  test "restart lands on the deployment, where it has always had a home", %{
    conn: conn,
    tenant: tenant
  } do
    import_compose(conn, tenant, @gluetun_compose)

    assert imported_deployment("gluetun").restart_policy_override == "unless-stopped"
  end

  test "command is imported in both compose spellings", %{conn: conn, tenant: tenant} do
    import_compose(conn, tenant, """
    services:
      minio:
        image: minio/minio:latest
        command: ["minio", "server", "/data"]
      shellform:
        image: app:latest
        command: serve --port 8080
    """)

    assert imported_template("minio").command == ["minio", "server", "/data"]
    # The shell form keeps its shell rather than being split on whitespace.
    assert imported_template("shellform").command == ["/bin/sh", "-c", "serve --port 8080"]
  end

  test "a service declaring none of them stores nil, so nothing shadows the catalog", %{
    conn: conn,
    tenant: tenant
  } do
    import_compose(conn, tenant, """
    services:
      plain:
        image: nginx:latest
    """)

    template = imported_template("plain")

    assert template.capabilities_add == nil
    assert template.devices == nil
    assert template.command == nil
  end

  # The import used to create every deployment ROW and then fall through to "Could not
  # start the deployment": `deploy_release/2` needs one row to be the app, and on a plain
  # compose import nothing filled that role. The rows were left orphaned at `:pending`
  # with no release planned — the import dead-ended at the point it looked like it worked.
  describe "the app a compose bundle is about" do
    test "a plain import actually plans a release instead of dead-ending", %{
      conn: conn,
      tenant: tenant
    } do
      import_compose(conn, tenant, @gluetun_compose)

      # Previously: one deployment row, zero releases, and an error flash.
      assert Repo.aggregate(Deployment, :count) == 1
      assert Repo.aggregate(Homelab.Deployments.Release, :count) == 1
    end

    test "the first non-datastore service is the app and carries the domain", %{
      conn: conn,
      tenant: tenant
    } do
      import_compose(
        conn,
        tenant,
        """
        services:
          db:
            image: postgres:16
          web:
            image: myapp:latest
        """,
        %{},
        "web.example.com"
      )

      # `db` sorts first in the file, but a datastore is never what the bundle is about.
      assert imported_deployment("web").domain == "web.example.com"
      assert imported_deployment("db").domain == nil
    end

    test "the release deploys the companions before the app", %{conn: conn, tenant: tenant} do
      import_compose(conn, tenant, """
      services:
        db:
          image: postgres:16
        web:
          image: myapp:latest
      """)

      release = Repo.one!(Homelab.Deployments.Release) |> Repo.preload(:steps)
      types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

      assert :dependency_container in types

      assert List.last(Enum.filter(types, &(&1 in [:dependency_container, :app_container]))) ==
               :app_container

      assert release.deployment_id == imported_deployment("web").id
    end

    test "advanced settings go to the app only, not copied onto every companion", %{
      conn: conn,
      tenant: tenant
    } do
      import_compose(
        conn,
        tenant,
        """
        services:
          db:
            image: postgres:16
          web:
            image: myapp:latest
        """,
        %{"routed_port" => "8443"}
      )

      assert imported_deployment("web").routed_port == 8443
      assert imported_deployment("db").routed_port == nil
    end
  end

  test "the Advanced panel is no longer discarded on the compose path", %{
    conn: conn,
    tenant: tenant
  } do
    import_compose(conn, tenant, @gluetun_compose, %{
      "memory_mb" => "2048",
      "capabilities_add" => "NET_RAW"
    })

    deployment = imported_deployment("gluetun")

    assert deployment.resource_limits_override == %{"memory_mb" => 2048}
    assert deployment.capabilities_add_override == ["NET_RAW"]
  end
end
