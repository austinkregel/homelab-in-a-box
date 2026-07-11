defmodule HomelabWeb.TelemetryLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Homelab.Telemetry

  @snapshot %{
    cpu_percent: 42.5,
    memory_percent: 60.0,
    memory_used: 8_000_000_000,
    memory_total: 16_000_000_000,
    disk: [%{mount: "/", total: 100, used: 55, percent: 55.0}],
    docker: %{
      "Containers" => 12,
      "ContainersRunning" => 9,
      "ContainersStopped" => 3,
      "Images" => 30,
      "ServerVersion" => "27.0.0"
    },
    traefik: %{
      "app-example-com" => %{
        requests_total: 1234,
        error_count: 7,
        requests_bytes_total: 999,
        responses_bytes_total: 888
      }
    }
  }

  describe "mount" do
    test "renders the telemetry page with the window selector", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/telemetry")

      assert html =~ "Telemetry"
      assert html =~ "Host, container, and traffic metrics over time."
      assert html =~ "30m"
      assert html =~ "3h"
      assert html =~ "24h"
    end

    test "shows the waiting state when the collector has no snapshot", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/telemetry")
      assert html =~ "Waiting for the metrics collector"
    end
  end

  describe "with metrics" do
    test "renders host, disk, docker, and traffic sections", %{conn: conn} do
      Telemetry.record_snapshot(@snapshot)

      {:ok, view, _html} = live(conn, ~p"/telemetry")
      send(view.pid, {:metrics, @snapshot})
      html = render(view)

      assert html =~ "Host resources"
      assert html =~ "CPU"
      assert html =~ "Memory"
      assert html =~ "Disk usage"
      assert html =~ "Docker host"
      assert html =~ "Docker storage"
      assert html =~ "Reverse-proxy traffic"
      assert html =~ "app-example-com"
      # Docker current counts surface.
      assert html =~ "27.0.0"
    end

    test "Docker storage panel degrades to unavailable when the daemon can't be reached",
         %{conn: conn} do
      # The test default Docker client is unreachable, so the async /system/df
      # load resolves to an error and the panel shows its fallback.
      {:ok, view, html} = live(conn, ~p"/telemetry")

      # Panel + refresh control are always present.
      assert html =~ "Docker storage"
      assert html =~ "refresh_docker_disk"

      # After the connected-mount :load_docker_disk message is processed.
      assert render(view) =~ "Docker daemon unavailable"
    end

    test "renders svg trend marks once samples exist", %{conn: conn} do
      Telemetry.record_snapshot(@snapshot)
      Telemetry.record_snapshot(@snapshot, DateTime.add(DateTime.utc_now(), -30, :second))

      {:ok, view, _html} = live(conn, ~p"/telemetry")
      send(view.pid, {:metrics, @snapshot})
      html = render(view)

      assert html =~ "<svg"
      assert html =~ "<path"
    end

    test "switching the window keeps the view alive and updates the active button", %{conn: conn} do
      Telemetry.record_snapshot(@snapshot)

      {:ok, view, _html} = live(conn, ~p"/telemetry")
      send(view.pid, {:metrics, @snapshot})

      html = view |> element("button", "24h") |> render_click()

      assert html =~ "Telemetry"
      # The 24h button now carries the active (primary) styling.
      assert html =~ "bg-primary text-primary-content"
    end
  end
end
