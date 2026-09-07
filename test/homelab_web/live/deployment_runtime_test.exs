defmodule HomelabWeb.DeploymentRuntimeTest do
  @moduledoc """
  The Runtime card: the properties that were hardcoded in both drivers (restart policy,
  replicas) or writable only by adoption (command, entrypoint, network aliases).
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

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

    template =
      insert(:app_template,
        command: ["serve"],
        entrypoint: ["/init"],
        network_aliases: ["app"]
      )

    %{deployment: insert(:deployment, app_template: template, status: :running)}
  end

  defp runtime_form(conn, deployment) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})
    view
  end

  # Only the fields under test are posted. Everything else round-trips from the form the
  # editor was seeded with, exactly as a partial change event does in the browser.
  defp submit(view, params) do
    render_submit(view, "save_settings", %{"settings" => params})
  end

  test "the card reports the effective values before editing", %{conn: conn, deployment: d} do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{d.id}")
    html = render_click(view, "switch_tab", %{"tab" => "settings"})

    assert html =~ "Runtime"
    assert html =~ "On failure"
    assert html =~ "serve"
    assert html =~ "/init"
  end

  test "a restart policy can be chosen at all, which it could not before", %{
    conn: conn,
    deployment: d
  } do
    view = runtime_form(conn, d)
    submit(view, %{"restart_policy" => "always"})

    assert Repo.reload!(d).restart_policy_override == "always"
  end

  test "a custom command is stored as one argument per line", %{conn: conn, deployment: d} do
    # Not split on whitespace: `--flag "a b"` would come apart, and the alternative is
    # implementing shell quoting in a form field.
    view = runtime_form(conn, d)

    submit(view, %{"command" => "serve\n--config\n/etc/app with spaces.conf"})

    assert Repo.reload!(d).command_override == ["serve", "--config", "/etc/app with spaces.conf"]
  end

  test "a custom-but-empty entrypoint clears the image's own", %{conn: conn, deployment: d} do
    # [] and nil mean different things to Docker, so the form has to be able to say both.
    view = runtime_form(conn, d)
    submit(view, %{"entrypoint" => ""})

    reloaded = Repo.reload!(d)
    assert reloaded.entrypoint_override == []
    refute reloaded.entrypoint_override == nil
  end

  test "typing the catalog's own command back in stores nil, so the catalog drives it again", %{
    conn: conn,
    deployment: d
  } do
    {:ok, pinned} =
      Homelab.Deployments.update_deployment(d, %{command_override: ["something-else"]})

    view = runtime_form(conn, pinned)
    submit(view, %{"command" => "serve"})

    assert Repo.reload!(d).command_override == nil
  end

  test "the editor is seeded with the effective command, not an empty box", %{
    conn: conn,
    deployment: d
  } do
    # The whole point of dropping the inherit toggle: what the container actually runs is
    # readable without leaving the page.
    view = runtime_form(conn, d)
    html = render(view)

    assert html =~ "serve"
    assert html =~ "/init"
  end

  test "network aliases are fixable, so a wrong adoption guess is recoverable", %{
    conn: conn,
    deployment: d
  } do
    # Adoption guesses these from the original's compose service name. When it guesses
    # wrong the stack's internal DNS is broken, and there was no way to correct it.
    view = runtime_form(conn, d)
    submit(view, %{"aliases" => "mysql\ndb"})

    assert Repo.reload!(d).network_aliases_override == ["mysql", "db"]
  end

  describe "kernel privileges" do
    test "capabilities are stored normalized, so one permission is one entry", %{
      conn: conn,
      deployment: d
    } do
      view = runtime_form(conn, d)

      submit(view, %{"caps_add" => ["", "cap_net_admin", "NET_ADMIN", "NET_RAW"]})

      assert Repo.reload!(d).capabilities_add_override == ["NET_ADMIN", "NET_RAW"]
    end

    test "a custom-but-empty capability list clears what the template grants", %{
      conn: conn,
      deployment: d
    } do
      # [] is a real hardening instruction here, distinct from "inherit the catalog's".
      {:ok, template} =
        Homelab.Catalog.update_app_template(d.app_template, %{capabilities_add: ["NET_ADMIN"]})

      d = %{d | app_template: template}

      view = runtime_form(conn, d)
      # The sentinel alone: every box cleared. Without it the payload would carry no key
      # at all, which is indistinguishable from the control not being rendered.
      submit(view, %{"caps_add" => [""]})

      assert Repo.reload!(d).capabilities_add_override == []
    end

    test "an unknown capability is refused rather than handed to the daemon", %{
      conn: conn,
      deployment: d
    } do
      view = runtime_form(conn, d)
      html = submit(view, %{"caps_add" => ["", "NET_ADMN"]})

      assert html =~ "unknown Linux capability: NET_ADMN"
      assert Repo.reload!(d).capabilities_add_override == nil
    end

    test "device rows are stored with the container path and permissions filled in", %{
      conn: conn,
      deployment: d
    } do
      view = runtime_form(conn, d)

      render_click(view, "settings_add_device", %{})
      submit(view, %{"devices" => %{"0" => %{"host_path" => "/dev/net/tun"}}})

      assert [device] = Repo.reload!(d).devices_override
      assert device["host_path"] == "/dev/net/tun"
      assert device["container_path"] == "/dev/net/tun"
      assert device["permissions"] == "rwm"
    end

    test "a device with a relative host path is refused", %{conn: conn, deployment: d} do
      view = runtime_form(conn, d)

      render_click(view, "settings_add_device", %{})
      html = submit(view, %{"devices" => %{"0" => %{"host_path" => "dev/net/tun"}}})

      assert html =~ "a device needs an absolute host path"
      assert Repo.reload!(d).devices_override == nil
    end

    test "sysctl rows are stored as a map, with blank keys dropped", %{conn: conn, deployment: d} do
      view = runtime_form(conn, d)

      render_click(view, "settings_add_sysctl", %{})
      render_click(view, "settings_add_sysctl", %{})

      submit(view, %{
        "sysctls" => %{
          "0" => %{"key" => "net.ipv4.conf.all.src_valid_mark", "value" => "1"},
          "1" => %{"key" => "", "value" => ""}
        }
      })

      assert Repo.reload!(d).sysctls_override == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
    end

    test "a sysctl outside a container's own namespace is refused", %{conn: conn, deployment: d} do
      view = runtime_form(conn, d)

      render_click(view, "settings_add_sysctl", %{})

      html =
        submit(view, %{"sysctls" => %{"0" => %{"key" => "vm.max_map_count", "value" => "262144"}}})

      assert html =~ "not in a namespace a container owns"
      assert Repo.reload!(d).sysctls_override == nil
    end

    test "clearing them all returns them to the catalog, which grants none", %{
      conn: conn,
      deployment: d
    } do
      {:ok, pinned} =
        Homelab.Deployments.update_deployment(d, %{
          capabilities_add_override: ["NET_ADMIN"],
          devices_override: [%{"host_path" => "/dev/net/tun"}],
          sysctls_override: %{"net.core.somaxconn" => "1024"}
        })

      view = runtime_form(conn, pinned)
      render_click(view, "settings_remove_device", %{"index" => "0"})
      render_click(view, "settings_remove_sysctl", %{"index" => "0"})
      submit(view, %{"caps_add" => [""]})

      reloaded = Repo.reload!(d)
      assert reloaded.capabilities_add_override == nil
      assert reloaded.devices_override == nil
      assert reloaded.sysctls_override == nil
    end

    test "an untouched save leaves every override exactly as it was", %{
      conn: conn,
      deployment: d
    } do
      # Merely opening Settings and saving must not move anything. This is the failure
      # the three-form split kept producing, in a different field each time.
      {:ok, pinned} =
        Homelab.Deployments.update_deployment(d, %{
          capabilities_add_override: ["NET_ADMIN"],
          devices_override: [%{"host_path" => "/dev/net/tun"}]
        })

      view = runtime_form(conn, pinned)
      submit(view, %{})

      reloaded = Repo.reload!(d)
      assert reloaded.capabilities_add_override == ["NET_ADMIN"]
      assert [%{"host_path" => "/dev/net/tun"}] = reloaded.devices_override
    end

    test "the read-only card reports the effective values", %{conn: conn, deployment: d} do
      {:ok, _} =
        Homelab.Deployments.update_deployment(d, %{
          capabilities_add_override: ["NET_ADMIN"],
          devices_override: [%{"host_path" => "/dev/net/tun"}],
          sysctls_override: %{"net.ipv4.conf.all.src_valid_mark" => "1"}
        })

      {:ok, view, _html} = live(conn, ~p"/deployments/#{d.id}")
      html = render_click(view, "switch_tab", %{"tab" => "settings"})

      assert html =~ "NET_ADMIN"
      assert html =~ "/dev/net/tun"
      assert html =~ "net.ipv4.conf.all.src_valid_mark=1"
    end
  end

  test "replicas above one are refused on Docker Engine", %{conn: conn, deployment: d} do
    # config/test.exs pins the Mox orchestrator, so name Engine explicitly.
    previous = Application.get_env(:homelab, :orchestrator)
    Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerEngine)
    on_exit(fn -> Application.put_env(:homelab, :orchestrator, previous) end)

    view = runtime_form(conn, d)
    html = submit(view, %{"replicas" => "3"})

    assert html =~ "requires Docker Swarm"
    assert Repo.reload!(d).replicas_override == nil
  end
end
