defmodule HomelabWeb.DeployWizardAdvancedTest do
  @moduledoc """
  The inverse of the create-only gap: resource limits, routed port, restart policy and
  sticky sessions were editable AFTER deploying but not offerable at create, so a GPU or
  multi-port app always came up wrong once and needed an immediate recreate.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Deployments.Deployment
  alias Homelab.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    %{
      tenant: insert(:tenant),
      template:
        insert(:app_template,
          name: "AdvApp",
          slug: "advapp",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )
    }
  end

  defp deploy_with(conn, template, tenant, advanced) do
    {:ok, view, _html} = live(conn, ~p"/deploy/new?step=review&template_id=#{template.id}")

    if advanced != %{}, do: render_change(view, "advanced_changed", %{"advanced" => advanced})

    render_click(view, "deploy", %{
      "tenant_id" => to_string(tenant.id),
      "exposure_mode" => "public",
      "domain" => "adv.example.com"
    })

    Repo.get_by!(Deployment, app_template_id: template.id)
  end

  test "the panel is offered on the review step", %{conn: conn, template: template} do
    {:ok, _view, html} = live(conn, ~p"/deploy/new?step=review&template_id=#{template.id}")

    assert html =~ "Advanced"
    assert html =~ "advanced[memory_mb]"
    assert html =~ "advanced[routed_port]"
    assert html =~ "advanced[restart_policy]"
  end

  test "resource limits are set at create instead of needing a recreate", %{
    conn: conn,
    template: template,
    tenant: tenant
  } do
    deployment =
      deploy_with(conn, template, tenant, %{"memory_mb" => "2048", "cpu_shares" => "1024"})

    assert deployment.resource_limits_override == %{"memory_mb" => 2048, "cpu_shares" => 1024}
  end

  test "the routed port is set at create, so a multi-port app routes correctly first time", %{
    conn: conn,
    template: template,
    tenant: tenant
  } do
    deployment = deploy_with(conn, template, tenant, %{"routed_port" => "8443"})

    assert deployment.routed_port == 8443
  end

  test "a restart policy other than the default is carried through", %{
    conn: conn,
    template: template,
    tenant: tenant
  } do
    deployment = deploy_with(conn, template, tenant, %{"restart_policy" => "always"})

    assert deployment.restart_policy_override == "always"
  end

  test "sticky sessions are set at create", %{conn: conn, template: template, tenant: tenant} do
    deployment = deploy_with(conn, template, tenant, %{"sticky" => "true"})

    assert deployment.proxy_options == %{"sticky" => true}
  end

  test "an untouched panel leaves everything inheriting from the template", %{
    conn: conn,
    template: template,
    tenant: tenant
  } do
    # A blank field must stay absent rather than becoming an explicit override — an
    # empty override wins over the template rather than deferring to it.
    deployment = deploy_with(conn, template, tenant, %{})

    assert deployment.resource_limits_override == nil
    assert deployment.routed_port == nil
    assert deployment.restart_policy_override == nil
  end

  test "blanks and junk are ignored rather than stored", %{
    conn: conn,
    template: template,
    tenant: tenant
  } do
    deployment =
      deploy_with(conn, template, tenant, %{
        "memory_mb" => "",
        "cpu_shares" => "not a number",
        "routed_port" => "0"
      })

    assert deployment.resource_limits_override == nil
    assert deployment.routed_port == nil
  end
end
