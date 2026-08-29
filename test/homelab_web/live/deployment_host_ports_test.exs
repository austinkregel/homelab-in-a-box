defmodule HomelabWeb.DeploymentHostPortsTest do
  @moduledoc """
  Publishing a host port from a PROXIED deployment — the settings-page half of the rule
  described in `Homelab.Deployments.Access`.

  The page used to stamp `published: access == "host"` over every port on save, so a
  proxied app could not bind a host port no matter what the form said. A git server is
  the shape that breaks: its web UI belongs behind Traefik and its SSH port cannot go
  through a reverse proxy at all, so "reached exactly one way" has to be a fact about
  each PORT rather than about the container.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Deployments
  alias Homelab.Deployments.SpecBuilder
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
        status: :running,
        external_id: "forgejo-1"
      )

    %{git: git}
  end

  defp save(conn, app, settings) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{app.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    defaults = %{"access" => "proxy", "auth" => "public"}
    html = render_submit(view, "save_settings", %{"settings" => Map.merge(defaults, settings)})

    {Repo.get!(Deployments.Deployment, app.id) |> Repo.preload([:tenant, :app_template]), html}
  end

  # The checkbox posts "true" only when ticked; an unticked box posts nothing at all,
  # which is why the parsed value has to be trusted rather than overwritten per mode.
  defp ssh_on_2222 do
    %{
      "domain" => "git.kregel.dev",
      "routed_port" => "3000",
      "ports" => %{
        "0" => %{"internal" => "3000", "role" => "web", "protocol" => "tcp"},
        "1" => %{
          "internal" => "22",
          "external" => "2222",
          "role" => "other",
          "protocol" => "tcp",
          "published" => "true"
        }
      }
    }
  end

  test "a proxied deployment keeps its route AND binds the port the proxy isn't carrying",
       %{conn: conn, git: git} do
    {updated, _html} = save(conn, git, ssh_on_2222())

    assert %{"internal" => "22", "external" => "2222", "published" => true} =
             Enum.find(updated.ports_override, &(&1["internal"] == "22"))

    assert %{"internal" => "3000", "published" => false} =
             Enum.find(updated.ports_override, &(&1["internal"] == "3000"))

    # And the spec the orchestrator actually receives agrees: SSH on the host, web behind
    # Traefik. Asserting on the saved row alone would pass even if `build_ports/1` still
    # dropped everything in proxy mode.
    assert {:ok, spec} = SpecBuilder.build(updated)

    assert [%{internal: "22", external: "2222"}] = spec.ports
    assert spec.labels["traefik.enable"] == "true"

    assert spec.labels["traefik.http.services.git-kregel-dev.loadbalancer.server.port"] ==
             "3000"
  end

  test "an unticked box publishes nothing — the default is still no host binding", %{
    conn: conn,
    git: git
  } do
    ports =
      ssh_on_2222()["ports"]
      |> put_in(["1"], Map.delete(ssh_on_2222()["ports"]["1"], "published"))

    {updated, _html} =
      save(conn, git, %{"domain" => "git.kregel.dev", "routed_port" => "3000", "ports" => ports})

    assert Enum.all?(updated.ports_override, &(&1["published"] == false))
    assert {:ok, spec} = SpecBuilder.build(updated)
    assert spec.ports == []
  end

  test "host mode still binds every listed port without a per-port checkbox", %{
    conn: conn,
    git: git
  } do
    {updated, _html} =
      save(conn, git, %{
        "access" => "host",
        "ports" => %{
          "0" => %{"internal" => "3000", "external" => "3000", "role" => "web"},
          "1" => %{"internal" => "22", "external" => "2222", "role" => "other"}
        }
      })

    assert Enum.all?(updated.ports_override, &(&1["published"] == true))
    assert {:ok, spec} = SpecBuilder.build(updated)
    assert length(spec.ports) == 2
  end

  # `editable_ports/1` and `ports_from_params/1` both used to drop `published` on the
  # floor. Since the save reads the CHECKBOX rather than the stored map, a dropped flag is
  # not a cosmetic glitch: the box renders unticked, and opening Settings and saving
  # anything at all takes the SSH binding away.
  describe "the flag survives a round-trip through the editor" do
    test "reopening Settings renders an already-published port as ticked", %{
      conn: conn,
      git: git
    } do
      {_updated, _html} = save(conn, git, ssh_on_2222())

      {:ok, view, _html} = live(conn, ~p"/deployments/#{git.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit", %{})

      assert has_element?(view, ~s(input[name="settings[ports][1][published]"])),
             "the SSH row should still offer a publish checkbox"

      assert has_element?(view, ~s(input[name="settings[ports][1][published]"][checked])),
             "the box rendered unticked for a port that is currently published"
    end

    test "saving an untouched form keeps the binding", %{conn: conn, git: git} do
      {_updated, _html} = save(conn, git, ssh_on_2222())

      {:ok, view, _html} = live(conn, ~p"/deployments/#{git.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit", %{})

      # A change event on an unrelated field, exactly as typing in the domain box would
      # produce -- the ports come back through `ports_from_params/1` here.
      render_change(view, "settings_changed", %{
        "settings" => %{
          "access" => "proxy",
          "auth" => "public",
          "domain" => "git.kregel.dev",
          "ports" => %{
            "0" => %{"internal" => "3000", "role" => "web", "protocol" => "tcp"},
            "1" => %{
              "internal" => "22",
              "external" => "2222",
              "role" => "other",
              "protocol" => "tcp",
              "published" => "true"
            }
          }
        }
      })

      assert has_element?(view, ~s(input[name="settings[ports][1][published]"][checked])),
             "the checkbox reverted on a change event, so the next save would unpublish 22"
    end
  end

  test "internal-only publishes nothing even with a ticked box", %{conn: conn, git: git} do
    {updated, _html} = save(conn, git, Map.put(ssh_on_2222(), "access", "internal"))

    assert Enum.all?(updated.ports_override, &(&1["published"] == false))
  end

  describe "a protected app's guarded ports" do
    # The checkbox for the routed port renders disabled, so this is the belt to that
    # brace: even a form that posts `published=true` for it must not produce a binding.
    test "the routed port is refused, and the save says so rather than silently dropping it",
         %{conn: conn, git: git} do
      {updated, html} =
        save(conn, git, %{
          "auth" => "sso_protected",
          "domain" => "git.kregel.dev",
          "routed_port" => "3000",
          "ports" => %{
            "0" => %{
              "internal" => "3000",
              "external" => "3000",
              "role" => "web",
              "published" => "true"
            }
          }
        })

      assert {:ok, spec} = SpecBuilder.build(updated)
      assert spec.ports == []
      assert html =~ "Port 3000 was not published to the host"
    end

    # A second router is a second door onto a port, so a port is only safe to publish if
    # NO router points at it -- not merely if it isn't the primary one.
    test "an extra path route's backend is refused too", %{conn: conn, git: git} do
      {updated, html} =
        save(conn, git, %{
          "auth" => "private",
          "domain" => "git.kregel.dev",
          "routed_port" => "3000",
          "ports" => %{
            "0" => %{"internal" => "3000", "role" => "web"},
            "1" => %{
              "internal" => "6001",
              "external" => "6001",
              "role" => "other",
              "published" => "true"
            }
          },
          "routes" => %{"0" => %{"path_prefix" => "/app", "port" => "6001"}}
        })

      assert {:ok, spec} = SpecBuilder.build(updated)
      assert spec.ports == []
      assert html =~ "Port 6001 was not published to the host"
    end

    # SSH is the case the whole feature exists for, and it must survive the guard: no
    # router points at 22, so protecting the web UI with SSO cannot take `git push` away.
    test "a port no router points at still publishes", %{conn: conn, git: git} do
      {updated, _html} =
        save(conn, git, Map.put(ssh_on_2222(), "auth", "sso_protected"))

      assert {:ok, spec} = SpecBuilder.build(updated)
      assert [%{internal: "22", external: "2222"}] = spec.ports
    end
  end
end
