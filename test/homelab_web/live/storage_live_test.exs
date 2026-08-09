defmodule HomelabWeb.StorageLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest
  import Homelab.Factory

  alias Homelab.Storage

  setup :set_mox_global

  setup do
    Homelab.Settings.evict("storage_mount_roots")
    on_exit(fn -> Homelab.Settings.delete("storage_mount_roots") end)
    :ok
  end

  defp stub_volumes(volumes) do
    stub(Homelab.Mocks.Orchestrator, :list_volumes, fn -> {:ok, volumes} end)
    :ok
  end

  defp volume(name, labels \\ %{}),
    do: %{name: name, driver: "local", labels: labels}

  describe "mount" do
    test "renders the three tabs", %{conn: conn} do
      stub_volumes([])

      {:ok, _view, html} = live(conn, ~p"/storage")

      assert html =~ "Storage"
      assert html =~ "Disks"
      assert html =~ "Volumes"
      assert html =~ "Folder mounts"
    end

    # `/system/df` is the slow call. The daemon is unreachable in test, so this also pins
    # that a failed size lookup degrades the page rather than taking it down.
    test "survives a daemon that cannot answer the disk-usage call", %{conn: conn} do
      stub_volumes([volume("orphan")])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      assert render(view) =~ "orphan"
    end

    test "reports a volume listing failure instead of rendering an empty list", %{conn: conn} do
      stub(Homelab.Mocks.Orchestrator, :list_volumes, fn -> {:error, :econnrefused} end)

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      assert render(view) =~ "Could not list volumes"
    end
  end

  describe "volumes tab" do
    test "shows the deployment that mounts a volume", %{conn: conn} do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "jellyfin", name: "Jellyfin", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [
          %{"container_path" => "/config", "type" => "volume", "source" => "jellyfin-config"}
        ]
      )

      stub_volumes([volume("jellyfin-config")])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")
      html = render(view)

      assert html =~ "jellyfin-config"
      assert html =~ "Jellyfin"
      assert html =~ "/config"
      refute html =~ "No deployment mounts this."
    end

    test "marks a volume nothing references", %{conn: conn} do
      stub_volumes([volume("leftovers")])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      assert render(view) =~ "No deployment mounts this."
    end

    test "flags a homelab-managed volume", %{conn: conn} do
      stub_volumes([volume("ours", %{"homelab.managed" => "true"})])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      assert render(view) =~ "managed"
    end

    # The confirm dialog exists to put the consumer list in front of the operator; a
    # delete that skipped straight to the daemon would take a stopped app's data with it.
    test "deleting names the deployments that still mount the volume", %{conn: conn} do
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "plex", name: "Plex", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [
          %{"container_path" => "/config", "type" => "volume", "source" => "plex-config"}
        ]
      )

      stub_volumes([volume("plex-config")])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      html =
        view
        |> element("button[phx-click='ask_delete_volume'][phx-value-name='plex-config']")
        |> render_click()

      assert html =~ "Delete plex-config?"
      assert html =~ "Plex"
      assert html =~ "still mounts it"
    end
  end

  describe "creating a volume" do
    test "a bad name is refused in the form rather than sent to the daemon", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      html =
        view
        |> element("button[phx-value-modal='volume']")
        |> render_click()

      assert html =~ "New volume"

      html =
        view
        |> form("form[phx-submit='create_volume']", volume: %{"name" => "not a valid name!"})
        |> render_submit()

      assert html =~ "letters, numbers"
    end

    test "a backing folder that does not exist is refused", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=volumes")

      view |> element("button[phx-value-modal='volume']") |> render_click()

      # The folder field only exists once "backed by a host folder" is picked — the
      # change event is what reveals it, so the submit has to come after.
      view
      |> form("form[phx-submit='create_volume']", volume: %{"backing" => "folder"})
      |> render_change()

      html =
        view
        |> form("form[phx-submit='create_volume']",
          volume: %{
            "name" => "cache",
            "backing" => "folder",
            "device" => "/nowhere/at/all/really"
          }
        )
        |> render_submit()

      assert html =~ "does not exist"
    end
  end

  describe "mounts tab" do
    test "lists a bind with the deployment that mounts it", %{conn: conn} do
      stub_volumes([])
      tenant = insert(:tenant, slug: "media")
      template = insert(:app_template, slug: "plex", name: "Plex", volumes: [])

      insert(:deployment,
        tenant: tenant,
        app_template: template,
        volumes_override: [
          %{"container_path" => "/media", "type" => "bind", "source" => "/mnt/tank/media"}
        ]
      )

      {:ok, view, _html} = live(conn, ~p"/storage?tab=mounts")
      html = render(view)

      assert html =~ "/mnt/tank/media"
      assert html =~ "Plex"
    end

    test "registers and forgets a mount root", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=mounts")

      view |> element("button[phx-value-modal='root']") |> render_click()

      html =
        view
        |> form("form[phx-submit='add_root']", root: %{"name" => "tank", "path" => "/mnt/tank"})
        |> render_submit()

      assert html =~ "tank"
      assert html =~ "/mnt/tank"
      assert [%{name: "tank"}] = Storage.custom_roots()

      view
      |> element("button[phx-click='delete_root'][phx-value-name='tank']")
      |> render_click()

      assert Storage.custom_roots() == []
    end

    test "a relative root is refused in the form", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=mounts")

      view |> element("button[phx-value-modal='root']") |> render_click()

      html =
        view
        |> form("form[phx-submit='add_root']", root: %{"name" => "tank", "path" => "mnt/tank"})
        |> render_submit()

      assert html =~ "absolute host path"
      assert Storage.custom_roots() == []
    end

    test "the built-in roots are listed and carry no delete control", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=mounts")
      html = render(view)

      assert html =~ "Adoption root"
      assert html =~ "Managed root"
      assert html =~ "built-in"
      refute html =~ "phx-value-name=\"Adoption root\""
    end

    test "attaching a mount needs a deployment", %{conn: conn} do
      stub_volumes([])

      {:ok, view, _html} = live(conn, ~p"/storage?tab=mounts")

      view |> element("button[phx-value-modal='mount']") |> render_click()

      html =
        view
        |> form("form[phx-submit='attach_mount']",
          mount: %{
            "deployment_id" => "",
            "type" => "bind",
            "source" => "/mnt/tank/media",
            "container_path" => "/media"
          }
        )
        |> render_submit()

      assert html =~ "pick a deployment"
    end
  end

  describe "authorization" do
    test "a member cannot reach the page", %{conn: conn} do
      member = insert(:user, role: :member)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in_user(member) |> live(~p"/storage")
    end
  end
end
