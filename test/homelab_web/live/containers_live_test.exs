defmodule HomelabWeb.ContainersLiveTest do
  @moduledoc """
  The page's whole reason for existing is the *unmanaged* tab, so most of what is pinned
  here is which containers reach it. The adoption scan narrows twice — once to unmanaged,
  once to in-scope — and this page must only apply the first.
  """

  use HomelabWeb.ConnCase, async: false

  import Mox
  import Phoenix.LiveViewTest

  setup :set_mox_global

  setup do
    Application.put_env(:homelab, :adoption_root, "/srv/homelab")
    Homelab.Settings.evict("adoption_root")

    on_exit(fn ->
      Application.delete_env(:homelab, :adoption_root)
      Homelab.Settings.evict("adoption_root")
    end)

    :ok
  end

  # A `GET /containers/json?all=true` row plus the `/containers/<id>/json` inspect the
  # discovery makes for each one.
  defp inspect_body(opts) do
    %{
      "Id" => opts[:id],
      "Name" => "/" <> opts[:name],
      "State" => %{"Status" => opts[:state] || "running"},
      "Config" => %{
        "Image" => opts[:image] || "example:latest",
        "Labels" => opts[:labels] || %{}
      },
      "HostConfig" => %{"RestartPolicy" => %{"Name" => "unless-stopped"}},
      "Mounts" => opts[:mounts] || []
    }
  end

  defp bind(source, target),
    do: %{"Type" => "bind", "Source" => source, "Destination" => target, "RW" => true}

  defp named_volume(name, target),
    do: %{
      "Type" => "volume",
      "Name" => name,
      "Source" => "/var/lib/docker/volumes/#{name}/_data",
      "Destination" => target,
      "RW" => true
    }

  defp stub_daemon(containers) do
    stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
      if String.starts_with?(path, "/containers/json") do
        {:ok, Enum.map(containers, &%{"Id" => &1[:id]})}
      else
        inspect_one(containers, path)
      end
    end)

    :ok
  end

  defp inspect_one(containers, path) do
    id = path |> String.split("/") |> Enum.at(2)

    case Enum.find(containers, &(&1[:id] == id)) do
      nil -> {:error, {:not_found, path}}
      container -> {:ok, inspect_body(container)}
    end
  end

  # `set_mox_global` makes the stub visible from the LiveView process, but
  # `Process.put(:docker_client, …)` does not — it is per-process by design. The
  # LiveView runs elsewhere, so the client has to be swapped where it will read it.
  setup do
    previous = Application.get_env(:homelab, :docker_client)
    Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
    on_exit(fn -> Application.put_env(:homelab, :docker_client, previous) end)
    :ok
  end

  describe "unmanaged tab" do
    test "lists a container this app did not deploy", %{conn: conn} do
      stub_daemon([
        [
          id: "abc123",
          name: "postgres-old",
          image: "postgres:14",
          mounts: [bind("/srv/homelab/pg", "/var/lib/postgresql/data")]
        ]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")
      html = render(view)

      assert html =~ "postgres-old"
      assert html =~ "postgres:14"
    end

    # The gap this page fills. `discover_in_scope/0` drops a container with no bind under
    # the adoption root, so a named-volume-only stack was invisible everywhere.
    test "lists an unmanaged container with no bind under the adoption root", %{conn: conn} do
      stub_daemon([
        [
          id: "def456",
          name: "redis-stray",
          image: "redis:7",
          mounts: [named_volume("redis-data", "/data")]
        ]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")
      html = render(view)

      assert html =~ "redis-stray"
      assert html =~ "no folder mounts at all"
    end

    test "explains why a bind outside the adoption root is not importable", %{conn: conn} do
      stub_daemon([
        [id: "ghi789", name: "nas-thing", mounts: [bind("/mnt/nas/stuff", "/data")]]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")

      assert render(view) =~ "no folder mount under /srv/homelab"
    end

    test "hides a container carrying the homelab.managed label", %{conn: conn} do
      stub_daemon([
        [
          id: "mmm111",
          name: "ours",
          labels: %{"homelab.managed" => "true"},
          mounts: [bind("/srv/homelab/ours", "/data")]
        ]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")

      refute render(view) =~ "ours"
    end

    test "offers the import path when something is actually importable", %{conn: conn} do
      stub_daemon([
        [id: "abc123", name: "sonarr", mounts: [bind("/srv/homelab/sonarr", "/config")]]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")
      html = render(view)

      assert html =~ "can be imported now"
      assert html =~ "Review import"
      assert html =~ "importable"
    end

    test "does not offer the import path when nothing is in scope", %{conn: conn} do
      stub_daemon([[id: "def456", name: "redis-stray", mounts: [named_volume("d", "/data")]]])

      {:ok, view, _html} = live(conn, ~p"/containers")

      refute render(view) =~ "can be imported now"
    end
  end

  describe "managed tab" do
    test "shows only the containers this app deployed", %{conn: conn} do
      stub_daemon([
        [id: "mmm111", name: "ours", labels: %{"homelab.managed" => "true"}],
        [id: "uuu222", name: "theirs"]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers?tab=managed")
      html = render(view)

      assert html =~ "ours"
      refute html =~ "theirs"
    end
  end

  describe "expanding a container" do
    test "reveals its mounts", %{conn: conn} do
      stub_daemon([
        [id: "abc123", name: "sonarr", mounts: [bind("/srv/homelab/sonarr", "/config")]]
      ])

      {:ok, view, _html} = live(conn, ~p"/containers")

      html =
        view
        |> element("button[phx-click='toggle'][phx-value-id='abc123']")
        |> render_click()

      assert html =~ "/srv/homelab/sonarr"
      assert html =~ "/config"
      assert html =~ "Container ID"
    end
  end

  describe "a daemon that will not answer" do
    test "says so instead of crashing the page", %{conn: conn} do
      Application.put_env(:homelab, :docker_client, Homelab.Docker.UnavailableClient)

      {:ok, view, _html} = live(conn, ~p"/containers")
      html = render(view)

      assert html =~ "Could not read the daemon"
      assert html =~ "connection_error"
      # And the page itself is still standing, not a crashed LiveView.
      assert html =~ "Containers"
      refute html =~ "phx-click=\"toggle\""
    end
  end

  describe "authorization" do
    test "a member cannot reach the page", %{conn: conn} do
      member = Homelab.Factory.insert(:user, role: :member)

      assert {:error, {:redirect, %{to: "/"}}} =
               conn |> log_in_user(member) |> live(~p"/containers")
    end
  end
end
