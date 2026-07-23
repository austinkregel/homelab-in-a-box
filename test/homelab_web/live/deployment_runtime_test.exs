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
    render_click(view, "start_runtime_edit", %{})
    view
  end

  defp submit(view, params) do
    defaults = %{
      "restart_policy" => "on-failure",
      "replicas" => "1",
      "command_mode" => "inherit",
      "command" => "",
      "entrypoint_mode" => "inherit",
      "entrypoint" => "",
      "aliases_mode" => "inherit",
      "aliases" => ""
    }

    render_submit(view, "save_runtime", %{"runtime" => Map.merge(defaults, params)})
  end

  test "the card reports the effective values before editing", %{conn: conn, deployment: d} do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{d.id}")
    html = render_click(view, "switch_tab", %{"tab" => "settings"})

    assert html =~ "Runtime"
    assert html =~ "on-failure"
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

    submit(view, %{
      "command_mode" => "custom",
      "command" => "serve\n--config\n/etc/app with spaces.conf"
    })

    assert Repo.reload!(d).command_override == ["serve", "--config", "/etc/app with spaces.conf"]
  end

  test "a custom-but-empty entrypoint clears the image's own", %{conn: conn, deployment: d} do
    # [] and nil mean different things to Docker, so the form has to be able to say both.
    view = runtime_form(conn, d)
    submit(view, %{"entrypoint_mode" => "custom", "entrypoint" => ""})

    reloaded = Repo.reload!(d)
    assert reloaded.entrypoint_override == []
    refute reloaded.entrypoint_override == nil
  end

  test "inherit stores nil, so the catalog still drives it", %{conn: conn, deployment: d} do
    {:ok, pinned} =
      Homelab.Deployments.update_deployment(d, %{command_override: ["something-else"]})

    view = runtime_form(conn, pinned)
    submit(view, %{"command_mode" => "inherit"})

    assert Repo.reload!(d).command_override == nil
  end

  test "network aliases are fixable, so a wrong adoption guess is recoverable", %{
    conn: conn,
    deployment: d
  } do
    # Adoption guesses these from the original's compose service name. When it guesses
    # wrong the stack's internal DNS is broken, and there was no way to correct it.
    view = runtime_form(conn, d)
    submit(view, %{"aliases_mode" => "custom", "aliases" => "mysql\ndb"})

    assert Repo.reload!(d).network_aliases_override == ["mysql", "db"]
  end

  test "replicas above one are refused on Docker Engine", %{conn: conn, deployment: d} do
    # config/test.exs pins the Mox orchestrator, so name Engine explicitly.
    previous = Application.get_env(:homelab, :orchestrator)
    Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerEngine)
    on_exit(fn -> Application.put_env(:homelab, :orchestrator, previous) end)

    view = runtime_form(conn, d)
    html = submit(view, %{"replicas" => "3"})

    assert html =~ "Could not save"
    assert Repo.reload!(d).replicas_override == nil
  end
end
