defmodule HomelabWeb.DeploymentDomainsTest do
  @moduledoc """
  The domain field on the deployment settings page, which takes a LIST.

  This page has an explicit Additional domains editor, so splitting a comma-joined
  primary field is a convenience here rather than the only way to express a second host
  — but the two inputs have to agree on what a comma means, or pasting the same value
  into each gives different results.
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

    app =
      insert(:deployment,
        tenant: insert(:tenant),
        app_template:
          insert(:app_template,
            name: "Synapse",
            slug: "synapse",
            ports: [%{"internal" => 8008, "role" => "web"}],
            exposure_mode: :public
          ),
        domain: "communication.ventures",
        status: :running,
        external_id: "synapse-1"
      )

    %{app: app}
  end

  defp save(conn, app, settings) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{app.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    defaults = %{"access" => "proxy", "auth" => "public"}
    render_submit(view, "save_settings", %{"settings" => Map.merge(defaults, settings)})

    Repo.get!(Deployments.Deployment, app.id)
  end

  test "a comma-joined primary field splits into a domain plus alias rows", %{
    conn: conn,
    app: app
  } do
    updated =
      save(conn, app, %{
        "domain" => "communication.ventures, matrix.communication.ventures"
      })

    assert updated.domain == "communication.ventures"
    assert [%{"host" => "matrix.communication.ventures"}] = updated.additional_domains
  end

  # `parse_additional_domains/1` only trims -- canonicalization happens later, in the
  # changeset -- while a host lifted out of the primary field arrives already normalized.
  # Comparing raw would leave two entries that normalize to ONE host: two routers racing
  # for one certificate.
  test "an alias already listed in a different spelling is not duplicated", %{
    conn: conn,
    app: app
  } do
    updated =
      save(conn, app, %{
        "domain" => "communication.ventures, matrix.communication.ventures",
        "domains" => %{"0" => %{"host" => "Matrix.Communication.Ventures", "port" => ""}}
      })

    assert updated.domain == "communication.ventures"

    assert [%{"host" => "matrix.communication.ventures"}] = updated.additional_domains,
           "the lifted host should have deduped against the differently-spelled row"
  end

  # An explicit row can carry a path_prefix and a port; a bare name lifted out of the
  # domain field carries neither. Letting the bare one win would silently strip the
  # `/.well-known/matrix` scoping off an alias the operator had already configured.
  test "an explicit alias row wins on collision, keeping its path scoping", %{
    conn: conn,
    app: app
  } do
    updated =
      save(conn, app, %{
        "domain" => "communication.ventures, matrix.communication.ventures",
        "domains" => %{
          "0" => %{
            "host" => "matrix.communication.ventures",
            "path_prefix" => "/.well-known/matrix",
            "port" => "8448"
          }
        }
      })

    assert [entry] = updated.additional_domains
    assert entry["host"] == "matrix.communication.ventures"
    assert entry["path_prefix"] == "/.well-known/matrix"
    assert entry["port"] == 8448
  end

  test "a plain single domain still saves unchanged", %{conn: conn, app: app} do
    updated = save(conn, app, %{"domain" => "communication.ventures"})

    assert updated.domain == "communication.ventures"
    assert updated.additional_domains == []
  end
end
