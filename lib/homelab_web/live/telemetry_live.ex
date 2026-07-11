defmodule HomelabWeb.TelemetryLive do
  @moduledoc """
  Dedicated telemetry dashboard: host CPU/memory/disk trends, Docker host state,
  and reverse-proxy traffic — all backed by the `metric_samples` time-series and
  a selectable look-back window.

  Series are seeded from persisted samples on mount and reloaded whenever a fresh
  snapshot is broadcast on `"metrics:update"` (the collector persists before it
  broadcasts, so the reload includes the newest point).
  """
  use HomelabWeb, :live_view

  alias Homelab.Telemetry
  alias Homelab.Tenants
  alias Homelab.System.DockerDisk

  # Look-back windows offered by the selector: {label, minutes}.
  @windows [{"30m", 30}, {"3h", 180}, {"24h", 1440}]
  @point_cap 240

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Homelab.PubSub, "metrics:update")
      # `/system/df` can be slow, so fetch it off the mount path once connected.
      send(self(), :load_docker_disk)
    end

    socket =
      socket
      |> assign(:page_title, "Telemetry")
      |> assign(:tenants, Tenants.list_tenants())
      |> assign(:windows, @windows)
      |> assign(:window_minutes, 30)
      |> assign(:metrics, latest_metrics())
      |> assign(:docker_disk, :loading)
      |> load_series()

    {:ok, socket}
  end

  @impl true
  def handle_info({:metrics, metrics}, socket) do
    {:noreply, socket |> assign(:metrics, metrics) |> load_series()}
  end

  def handle_info(:load_docker_disk, socket) do
    {:noreply, assign(socket, :docker_disk, load_docker_disk())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("set_window", %{"minutes" => minutes}, socket) do
    minutes = String.to_integer(minutes)
    {:noreply, socket |> assign(:window_minutes, minutes) |> load_series()}
  end

  def handle_event("refresh_docker_disk", _params, socket) do
    send(self(), :load_docker_disk)
    {:noreply, assign(socket, :docker_disk, :loading)}
  end

  # --- Data loading ---------------------------------------------------------

  defp latest_metrics do
    Homelab.Services.MetricsCollector.get_latest()
  rescue
    _ -> nil
  catch
    :exit, _ -> nil
  end

  # Returns {:ok, summary} | {:error, reason}; never raises so the panel can show
  # an "unavailable" state instead of crashing the dashboard.
  defp load_docker_disk do
    DockerDisk.collect()
  rescue
    e -> {:error, e}
  catch
    :exit, reason -> {:error, reason}
  end

  defp load_series(socket) do
    opts = [minutes: socket.assigns.window_minutes, limit: @point_cap]

    socket
    |> assign(:cpu_series, safe_series(fn -> Telemetry.host_series("cpu_percent", opts) end))
    |> assign(:mem_series, safe_series(fn -> Telemetry.host_series("memory_percent", opts) end))
    |> assign(:disk_series, load_disk_series(opts))
    |> assign(
      :docker_series,
      safe_series(fn ->
        Telemetry.series([source: "docker", metric: "containers_running"] ++ opts)
      end)
    )
    |> assign(:traefik_series, load_traefik_series(opts))
  end

  # One entry per disk mount seen in the window, newest value first-class for the
  # headline. Subjects are stored as "disk:<mount>".
  defp load_disk_series(opts) do
    safe_series(fn -> Telemetry.subjects("host", "disk_percent", opts) end)
    |> Enum.map(fn subject ->
      mount = String.replace_prefix(subject, "disk:", "")

      series =
        safe_series(fn ->
          Telemetry.series([source: "host", subject: subject, metric: "disk_percent"] ++ opts)
        end)

      %{mount: mount, series: series, current: last_value(series)}
    end)
  end

  defp load_traefik_series(opts) do
    safe_series(fn -> Telemetry.subjects("traefik", "requests_total", opts) end)
    |> Enum.map(fn service ->
      requests =
        safe_series(fn ->
          Telemetry.series(
            [source: "traefik", subject: service, metric: "requests_total"] ++ opts
          )
        end)

      errors =
        safe_series(fn ->
          Telemetry.series([source: "traefik", subject: service, metric: "error_count"] ++ opts)
        end)

      %{
        service: service,
        requests_series: requests,
        requests_total: last_value(requests),
        error_count: last_value(errors)
      }
    end)
    |> Enum.sort_by(& &1.requests_total, :desc)
  end

  # Telemetry queries hit the DB; if it's unavailable (e.g. collector never ran)
  # we degrade to empty rather than crashing the dashboard.
  defp safe_series(fun) do
    fun.()
  rescue
    _ -> []
  end

  defp last_value([]), do: nil
  defp last_value(series), do: List.last(series)[:value]

  # --- Render ---------------------------------------------------------------

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      tenants={@tenants}
      current_user={@current_user}
      notification_count={@notification_count}
      notifications={@notifications}
    >
      <div class="space-y-5">
        <%!-- Header + window selector --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold text-base-content tracking-tight">Telemetry</h1>
            <p class="text-sm text-base-content/50 mt-0.5">
              Host, container, and traffic metrics over time.
            </p>
          </div>
          <div class="inline-flex rounded-lg border border-base-content/[0.1] overflow-hidden">
            <button
              :for={{label, minutes} <- @windows}
              phx-click="set_window"
              phx-value-minutes={minutes}
              class={[
                "px-3 py-1.5 text-sm font-medium transition-colors",
                if(@window_minutes == minutes,
                  do: "bg-primary text-primary-content",
                  else: "text-base-content/60 hover:bg-base-200"
                )
              ]}
            >
              {label}
            </button>
          </div>
        </div>

        <%= if @metrics do %>
          <%!-- Host resource trends --%>
          <div>
            <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-2">
              Host resources
            </h2>
            <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
              <.area_chart
                label="CPU"
                series={@cpu_series}
                color="primary"
                format={&format_percent/1}
              />
              <.area_chart
                label="Memory"
                series={@mem_series}
                color="info"
                format={&format_percent/1}
              />
            </div>
          </div>

          <%!-- Disk per mount --%>
          <div :if={@disk_series != []}>
            <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-2">
              Disk usage
            </h2>
            <div class="grid grid-cols-1 md:grid-cols-2 lg:grid-cols-3 gap-3">
              <.area_chart
                :for={disk <- @disk_series}
                label={disk.mount}
                series={disk.series}
                color="warning"
                format={&format_percent/1}
                height_class="h-24"
              />
            </div>
          </div>

          <%!-- Docker host --%>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-4">
            <div class="flex items-center justify-between mb-3">
              <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">
                Docker host
              </h2>
              <span class="text-[11px] text-base-content/30">
                {docker_field(@metrics, "ServerVersion")}
              </span>
            </div>
            <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 mb-3">
              <.mini_stat label="Running" value={docker_field(@metrics, "ContainersRunning")} />
              <.mini_stat label="Total" value={docker_field(@metrics, "Containers")} />
              <.mini_stat label="Stopped" value={docker_field(@metrics, "ContainersStopped")} />
              <.mini_stat label="Images" value={docker_field(@metrics, "Images")} />
            </div>
            <.sparkline
              :if={@docker_series != []}
              points={@docker_series}
              color="success"
              class="w-full h-10"
            />
          </div>

          <%!-- Reverse-proxy traffic --%>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
            <div class="px-4 py-3 border-b border-base-content/[0.06]">
              <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">
                Reverse-proxy traffic
              </h2>
            </div>
            <%= if @traefik_series == [] do %>
              <p class="px-4 py-6 text-sm text-base-content/40 text-center">
                No traffic metrics yet. Traffic appears once Traefik is reachable and serving requests.
              </p>
            <% else %>
              <div class="divide-y divide-base-content/[0.06]">
                <div :for={svc <- @traefik_series} class="px-4 py-3 flex items-center gap-4">
                  <div class="flex-1 min-w-0">
                    <p class="text-sm font-medium text-base-content truncate">{svc.service}</p>
                    <p class="text-xs text-base-content/40">
                      {format_count(svc.requests_total)} requests · {format_count(svc.error_count)} errors
                    </p>
                  </div>
                  <div class="w-32 shrink-0">
                    <.sparkline points={svc.requests_series} color="primary" class="w-full h-8" />
                  </div>
                </div>
              </div>
            <% end %>
          </div>
        <% else %>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-10 text-center">
            <.icon name="hero-chart-bar" class="size-8 text-base-content/20 mx-auto mb-3" />
            <p class="text-sm text-base-content/50">
              Waiting for the metrics collector to report its first snapshot…
            </p>
          </div>
        <% end %>

        <%!-- Docker storage (volumes/images) — from the daemon, since managed
             volumes aren't mounted into this container and df can't see them. --%>
        <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
          <div class="px-4 py-3 border-b border-base-content/[0.06] flex items-center justify-between">
            <div>
              <h2 class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">
                Docker storage
              </h2>
              <p class="text-[11px] text-base-content/30 mt-0.5">
                Volumes, images &amp; build cache reported by the Docker daemon.
              </p>
            </div>
            <button
              phx-click="refresh_docker_disk"
              class="flex items-center gap-1.5 px-2.5 py-1.5 rounded-lg border border-base-content/[0.1] text-xs font-medium text-base-content/60 hover:bg-base-200 transition-colors"
              disabled={@docker_disk == :loading}
            >
              <.icon
                name="hero-arrow-path"
                class={["size-3.5", @docker_disk == :loading && "animate-spin"]}
              /> Refresh
            </button>
          </div>

          <%= case @docker_disk do %>
            <% :loading -> %>
              <p class="px-4 py-6 text-sm text-base-content/40 text-center">
                Reading Docker disk usage…
              </p>
            <% {:ok, df} -> %>
              <div class="grid grid-cols-2 sm:grid-cols-4 gap-3 p-4">
                <.mini_stat label="Volumes" value={"#{format_bytes(df.volumes.size)}"} />
                <.mini_stat label="Images" value={"#{format_bytes(df.images.size)}"} />
                <.mini_stat label="Containers" value={"#{format_bytes(df.containers.size)}"} />
                <.mini_stat label="Build cache" value={"#{format_bytes(df.build_cache.size)}"} />
              </div>
              <p class="px-4 -mt-1 pb-2 text-[11px] text-base-content/30">
                {df.volumes.count} volumes · {df.volumes.active} in use · {format_bytes(
                  df.volumes.reclaimable
                )} reclaimable (unused)
              </p>
              <%= if df.volumes.items == [] do %>
                <p class="px-4 py-4 text-sm text-base-content/40 text-center">No Docker volumes.</p>
              <% else %>
                <div class="max-h-80 overflow-y-auto border-t border-base-content/[0.06] divide-y divide-base-content/[0.06]">
                  <div :for={vol <- df.volumes.items} class="px-4 py-2.5 flex items-center gap-3">
                    <span class={[
                      "w-1.5 h-1.5 rounded-full shrink-0",
                      if(vol.in_use, do: "bg-success", else: "bg-base-content/20")
                    ]}>
                    </span>
                    <p class="flex-1 min-w-0 text-sm text-base-content truncate" title={vol.name}>
                      {vol.name}
                    </p>
                    <span
                      :if={!vol.in_use}
                      class="text-[10px] uppercase tracking-wider text-base-content/30"
                    >
                      unused
                    </span>
                    <span class="text-sm font-medium text-base-content/70 tabular-nums shrink-0">
                      {format_bytes(vol.size)}
                    </span>
                  </div>
                </div>
              <% end %>
            <% {:error, _reason} -> %>
              <p class="px-4 py-6 text-sm text-base-content/40 text-center">
                Docker daemon unavailable — can't read volume usage right now.
              </p>
          <% end %>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :any, required: true

  defp mini_stat(assigns) do
    # `@value` is already display-ready (a small count or a preformatted string);
    # rendered verbatim so byte-formatted values aren't mangled by count logic.
    ~H"""
    <div class="rounded-lg bg-base-200/50 p-3">
      <p class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">{@label}</p>
      <p class="text-xl font-bold text-base-content mt-0.5">{@value}</p>
    </div>
    """
  end

  # --- Formatting -----------------------------------------------------------

  defp docker_field(%{docker: docker}, key) when is_map(docker), do: Map.get(docker, key, "—")
  defp docker_field(_, _), do: "—"

  defp format_percent(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)}%"
  defp format_percent(_), do: "—"

  defp format_count(n) when is_number(n) do
    cond do
      n >= 1_000_000 -> "#{Float.round(n / 1_000_000, 1)}M"
      n >= 1_000 -> "#{Float.round(n / 1_000, 1)}K"
      true -> "#{trunc(n)}"
    end
  end

  defp format_count(_), do: "—"

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{trunc(bytes)} B"
    end
  end

  defp format_bytes(_), do: "—"
end
