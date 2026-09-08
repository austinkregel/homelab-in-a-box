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
    # Opening Settings asks the image's registry which tags exist. Nothing here reads
    # that list, and the real Docker Hub driver answers by opening a TLS connection to
    # hub.docker.com, so offer no registry at all: `Tags.supported?/1` is then false and
    # the version field stays the free-text control it degrades to anyway.
    previous_registries = Application.get_env(:homelab, :registries)
    Application.put_env(:homelab, :registries, [])
    on_exit(fn -> restore(:registries, previous_registries) end)

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

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, value), do: Application.put_env(:homelab, key, value)

  defp save(conn, app, settings) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{app.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    render_click(view, "start_settings_edit", %{})

    defaults = %{"namespace" => "own", "auth" => "public"}
    html = save_settings(view, Map.merge(defaults, settings))

    {Repo.get!(Deployments.Deployment, app.id) |> Repo.preload([:tenant, :app_template]), html}
  end

  # A save plans a release, and the deployment/release broadcasts that follow are handled
  # AFTER the submit's reply — each one reloading the deployment from the Repo. `render/1`
  # is a synchronous round-trip queued behind those messages, so the assertions read a
  # page that has finished reloading rather than one still mid-flight.
  defp save_settings(view, settings) do
    render_submit(view, "save_settings", %{"settings" => settings})
    render(view)
  end

  # Exposure is a property of the PORT, chosen per row: the web UI goes behind Traefik
  # and SSH binds the host, in one table, because a reverse proxy has nothing to say
  # about SSH.
  defp ssh_on_2222 do
    %{
      "routes" => %{"0" => %{"host" => "git.kregel.dev", "port" => "3000"}},
      "ports" => %{
        "0" => %{
          "internal" => "3000",
          "role" => "web",
          "protocol" => "tcp",
          "exposure" => "proxy"
        },
        "1" => %{
          "internal" => "22",
          "external" => "2222",
          "role" => "other",
          "protocol" => "tcp",
          "exposure" => "host"
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

  test "an internal port publishes nothing — the default is still no host binding", %{
    conn: conn,
    git: git
  } do
    ports = put_in(ssh_on_2222()["ports"], ["1", "exposure"], "internal")

    {updated, _html} =
      save(conn, git, %{
        "routes" => %{"0" => %{"host" => "git.kregel.dev", "port" => "3000"}},
        "ports" => ports
      })

    assert Enum.all?(updated.ports_override, &(&1["published"] == false))
    assert {:ok, spec} = SpecBuilder.build(updated)
    assert spec.ports == []
  end

  test "every port set to Published binds, with no route in the way", %{
    conn: conn,
    git: git
  } do
    {updated, _html} =
      save(conn, git, %{
        "routes" => %{},
        "ports" => %{
          "0" => %{
            "internal" => "3000",
            "external" => "3000",
            "role" => "web",
            "exposure" => "host"
          },
          "1" => %{
            "internal" => "22",
            "external" => "2222",
            "role" => "other",
            "exposure" => "host"
          }
        }
      })

    assert Enum.all?(updated.ports_override, &(&1["published"] == true))
    assert {:ok, spec} = SpecBuilder.build(updated)
    assert length(spec.ports) == 2
  end

  # The host binding is not stored as a checkbox any more, but the failure it guards
  # against is the same one: a value the editor drops on the floor renders as its
  # default, so merely opening Settings and saving takes the SSH binding away.
  describe "the exposure survives a round-trip through the editor" do
    test "reopening Settings renders an already-published port as Published", %{
      conn: conn,
      git: git
    } do
      {_updated, _html} = save(conn, git, ssh_on_2222())

      {:ok, view, _html} = live(conn, ~p"/deployments/#{git.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit", %{})

      assert has_element?(view, ~s(select[name="settings[ports][1][exposure]"])),
             "the SSH row should offer an exposure control"

      assert has_element?(
               view,
               ~s(select[name="settings[ports][1][exposure]"] option[value="host"][selected])
             ),
             "the row read as internal for a port that is currently published"
    end

    test "an untouched save keeps the binding", %{conn: conn, git: git} do
      {_updated, _html} = save(conn, git, ssh_on_2222())

      {:ok, view, _html} = live(conn, ~p"/deployments/#{git.id}")
      render_click(view, "switch_tab", %{"tab" => "settings"})
      render_click(view, "start_settings_edit", %{})

      # Nothing is posted at all: every field round-trips from the form the editor was
      # seeded with, which is what makes an untouched save a no-op.
      html = save_settings(view, %{})
      refute html =~ "was not published"

      updated = Repo.get!(Deployments.Deployment, git.id)

      assert %{"internal" => "22", "external" => "2222", "published" => true} =
               Enum.find(updated.ports_override, &(&1["internal"] == "22"))
    end
  end

  test "internal-only publishes nothing", %{conn: conn, git: git} do
    ports =
      ssh_on_2222()["ports"]
      |> put_in(["0", "exposure"], "internal")
      |> put_in(["1", "exposure"], "internal")

    {updated, _html} = save(conn, git, %{"routes" => %{}, "ports" => ports})

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
          "routes" => %{"0" => %{"host" => "git.kregel.dev", "port" => "3000"}},
          "ports" => %{
            "0" => %{
              "internal" => "3000",
              "external" => "3000",
              "role" => "web",
              "exposure" => "host"
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
          "ports" => %{
            "0" => %{"internal" => "3000", "role" => "web", "exposure" => "proxy"},
            "1" => %{
              "internal" => "6001",
              "external" => "6001",
              "role" => "other",
              "exposure" => "host"
            }
          },
          "routes" => %{
            "0" => %{"host" => "git.kregel.dev", "port" => "3000"},
            "1" => %{"host" => "git.kregel.dev", "path_prefix" => "/app", "port" => "6001"}
          }
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
