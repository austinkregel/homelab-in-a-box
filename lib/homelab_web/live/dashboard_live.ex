defmodule HomelabWeb.DashboardLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant
  alias Homelab.Deployments
  alias Homelab.Catalog
  alias Homelab.Services.ActivityLog

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      :timer.send_interval(5000, self(), :refresh)
      Phoenix.PubSub.subscribe(Homelab.PubSub, "metrics:update")
      Phoenix.PubSub.subscribe(Homelab.PubSub, ActivityLog.topic())
    end

    socket =
      socket
      |> assign(:page_title, "Dashboard")
      |> assign(:show_create_space, false)
      |> assign(:space_form, to_form(Tenants.change_tenant(%Tenant{})))
      |> assign(:metrics, nil)
      |> assign(:activity_events, ActivityLog.recent(15))
      |> load_dashboard_data()
      |> load_metrics()

    {:ok, socket}
  end

  @impl true
  def handle_info(:refresh, socket) do
    {:noreply,
     socket
     |> load_dashboard_data()}
  end

  def handle_info({:metrics, metrics}, socket) do
    {:noreply, assign(socket, :metrics, metrics)}
  end

  def handle_info({:metrics_update, metrics}, socket) do
    {:noreply, assign(socket, :metrics, metrics)}
  end

  def handle_info({:activity_event, event}, socket) do
    events = [event | socket.assigns.activity_events] |> Enum.take(15)
    {:noreply, assign(socket, :activity_events, events)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  @impl true
  def handle_event("open_create_space", _params, socket) do
    form = to_form(Tenants.change_tenant(%Tenant{}))

    {:noreply,
     socket
     |> assign(:show_create_space, true)
     |> assign(:space_form, form)}
  end

  def handle_event("close_create_space", _params, socket) do
    {:noreply, assign(socket, :show_create_space, false)}
  end

  def handle_event("validate_space", %{"tenant" => params}, socket) do
    form =
      %Tenant{}
      |> Tenants.change_tenant(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :space_form, form)}
  end

  def handle_event("save_space", %{"tenant" => params}, socket) do
    case Tenants.create_tenant(params) do
      {:ok, _tenant} ->
        {:noreply,
         socket
         |> assign(:show_create_space, false)
         |> put_flash(:info, "Space created successfully!")
         |> load_dashboard_data()}

      {:error, changeset} ->
        {:noreply, assign(socket, :space_form, to_form(changeset))}
    end
  end

  def handle_event("navigate_deployment", %{"id" => id}, socket) do
    {:noreply, push_navigate(socket, to: ~p"/deployments/#{id}")}
  end

  def handle_event("generate_slug", %{"value" => name}, socket) do
    slug = slugify(name)
    params = %{"name" => name, "slug" => slug}

    form =
      %Tenant{}
      |> Tenants.change_tenant(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :space_form, form)}
  end

  defp load_dashboard_data(socket) do
    tenants = Tenants.list_tenants()
    deployments = Deployments.list_deployments()
    templates = Catalog.list_app_templates()

    deployment_counts =
      Enum.group_by(deployments, & &1.status)
      |> Map.new(fn {status, deps} -> {status, length(deps)} end)

    socket
    |> assign(:tenants, tenants)
    |> assign(:deployments, deployments)
    |> assign(:templates_count, length(templates))
    |> assign(:deployment_counts, deployment_counts)
    |> assign(:total_deployments, length(deployments))
  end

  defp load_metrics(socket) do
    metrics =
      try do
        case Homelab.Services.MetricsCollector.get_latest() do
          nil -> nil
          m -> m
        end
      rescue
        _ -> nil
      catch
        :exit, _ -> nil
      end

    assign(socket, :metrics, metrics)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      tenants={@tenants}
      current_user={@current_user}
    >
      <div class="space-y-5">
        <%!-- Hero header --%>
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-xl font-semibold text-base-content tracking-tight">Dashboard</h1>
            <p class="text-sm text-base-content/50 mt-0.5">
              Your self-hosted infrastructure at a glance.
            </p>
          </div>
          <.link
            navigate={~p"/catalog"}
            class="flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            <.icon name="hero-plus-mini" class="size-4" />
            <span>Deploy App</span>
          </.link>
        </div>

        <%!-- System health --%>
        <%= if @metrics do %>
          <div class="grid grid-cols-1 md:grid-cols-3 gap-3">
            <.resource_gauge
              label="CPU"
              percent={@metrics[:cpu_percent] || 0}
              detail={format_percent(@metrics[:cpu_percent])}
              color="primary"
            />
            <.resource_gauge
              label="Memory"
              percent={@metrics[:memory_percent] || 0}
              detail={"#{format_bytes(@metrics[:memory_used] || 0)} / #{format_bytes(@metrics[:memory_total] || 0)}"}
              color="info"
            />
            <.resource_gauge
              label="Docker"
              percent={0}
              detail={"#{docker_containers_running(@metrics)} containers running"}
              color="success"
            />
          </div>
        <% end %>

        <%!-- Stat cards --%>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-3">
          <.stat_card
            label="Spaces"
            value={length(@tenants)}
            icon="hero-user-group"
            color="primary"
            description="Active environments"
          />
          <.stat_card
            label="Deployments"
            value={@total_deployments}
            icon="hero-cube"
            color="info"
            description="Total apps deployed"
          />
          <.stat_card
            label="Running"
            value={Map.get(@deployment_counts, :running, 0)}
            icon="hero-check-circle"
            color="success"
            description="Healthy and online"
          />
          <.stat_card
            label="Pending"
            value={
              Map.get(@deployment_counts, :pending, 0) + Map.get(@deployment_counts, :deploying, 0)
            }
            icon="hero-clock"
            color="warning"
            description="Awaiting deployment"
          />
        </div>

        <%!-- Traffic overview --%>
        <.traffic_overview metrics={@metrics} deployments={@deployments} />

        <%!-- System activity --%>
        <.activity_panel events={@activity_events} />

        <%!-- Content panels --%>
        <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
          <%!-- Spaces panel --%>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
            <div class="px-4 py-3 border-b border-base-content/[0.06] flex items-center justify-between">
              <div class="flex items-center gap-2.5">
                <div class="w-7 h-7 rounded-lg bg-primary/10 flex items-center justify-center">
                  <.icon name="hero-user-group-mini" class="size-3.5 text-primary" />
                </div>
                <h2 class="text-sm font-semibold text-base-content">Spaces</h2>
              </div>
              <button
                type="button"
                phx-click="open_create_space"
                class="flex items-center gap-1 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
              >
                <.icon name="hero-plus-mini" class="size-3.5" /> New
              </button>
            </div>

            <div :if={@tenants == []} class="px-4 py-8 text-center">
              <div class="mx-auto w-14 h-14 rounded-lg bg-base-200/80 flex items-center justify-center mb-3">
                <.icon name="hero-folder-plus" class="size-6 text-base-content/20" />
              </div>
              <p class="text-sm font-medium text-base-content/60 mb-1">No spaces yet</p>
              <p class="text-xs text-base-content/35 leading-relaxed max-w-[200px] mx-auto mb-3">
                Spaces group your deployments into isolated environments.
              </p>
              <button
                type="button"
                phx-click="open_create_space"
                class="inline-flex items-center gap-1.5 text-xs font-semibold text-primary hover:text-primary/80 transition-colors cursor-pointer"
              >
                <.icon name="hero-plus-mini" class="size-3.5" /> Create your first space
              </button>
            </div>

            <div :if={@tenants != []} class="divide-y divide-base-content/[0.06]">
              <.link
                :for={tenant <- @tenants}
                navigate={~p"/tenants/#{tenant.id}"}
                class="flex items-center justify-between px-4 py-3 hover:bg-base-content/[0.02] transition-colors"
              >
                <div class="flex items-center gap-3.5 min-w-0">
                  <div class="w-9 h-9 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0">
                    <.icon name="hero-folder-solid" class="size-4 text-primary" />
                  </div>
                  <div class="min-w-0">
                    <p class="text-sm font-medium text-base-content truncate">{tenant.name}</p>
                    <p class="text-xs text-base-content/35 font-mono">{tenant.slug}</p>
                  </div>
                </div>
                <.status_pill status={tenant.status} />
              </.link>
            </div>
          </div>

          <%!-- Deployments panel --%>
          <div class="lg:col-span-2 rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
            <div class="px-4 py-3 border-b border-base-content/[0.06] flex items-center justify-between">
              <div class="flex items-center gap-2.5">
                <div class="w-7 h-7 rounded-lg bg-info/10 flex items-center justify-center">
                  <.icon name="hero-cube-mini" class="size-3.5 text-info" />
                </div>
                <h2 class="text-sm font-semibold text-base-content">Recent Deployments</h2>
              </div>
              <span class="text-xs font-medium text-base-content/30">
                {length(@deployments)} total
              </span>
            </div>

            <div :if={@deployments == []} class="px-4 py-8 text-center">
              <div class="mx-auto w-14 h-14 rounded-lg bg-base-200/80 flex items-center justify-center mb-3">
                <.icon name="hero-rocket-launch" class="size-6 text-base-content/20" />
              </div>
              <p class="text-sm font-medium text-base-content/60 mb-1">No deployments yet</p>
              <p class="text-xs text-base-content/35 leading-relaxed max-w-[260px] mx-auto mb-3">
                Deploy your first app from the catalog and it will appear here.
              </p>
              <.link
                navigate={~p"/catalog"}
                class="inline-flex items-center gap-1.5 text-xs font-semibold text-primary hover:text-primary/80 transition-colors"
              >
                <.icon name="hero-arrow-right-mini" class="size-3.5" /> Browse the catalog
              </.link>
            </div>

            <div :if={@deployments != []}>
              <table class="w-full">
                <thead>
                  <tr class="border-b border-base-content/[0.06]">
                    <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-2.5">
                      App
                    </th>
                    <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-2.5">
                      Space
                    </th>
                    <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-2.5">
                      Status
                    </th>
                    <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-2.5">
                      Domain
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-base-content/[0.04]">
                  <tr
                    :for={deployment <- Enum.take(@deployments, 10)}
                    phx-click="navigate_deployment"
                    phx-value-id={deployment.id}
                    class="hover:bg-base-content/[0.02] transition-colors cursor-pointer"
                  >
                    <td class="px-4 py-3">
                      <span class="text-sm font-medium text-base-content">
                        {deployment.app_template.name}
                      </span>
                    </td>
                    <td class="px-4 py-3">
                      <span class="text-sm text-base-content/50">{deployment.tenant.name}</span>
                    </td>
                    <td class="px-4 py-3">
                      <.status_pill status={deployment.status} />
                      <p
                        :if={deployment.status == :failed && deployment.error_message}
                        class="text-[11px] text-error/70 mt-1 max-w-[220px] truncate"
                        title={deployment.error_message}
                      >
                        {deployment.error_message}
                      </p>
                    </td>
                    <td class="px-4 py-3">
                      <span :if={deployment.domain} class="text-sm text-base-content/50 font-mono">
                        {deployment.domain}
                      </span>
                      <span :if={!deployment.domain} class="text-sm text-base-content/15">
                        &mdash;
                      </span>
                    </td>
                  </tr>
                </tbody>
              </table>
            </div>
          </div>
        </div>
        <%!-- Create Space Modal --%>
        <div
          :if={@show_create_space}
          id="create-space-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_create_space"
          phx-key="escape"
        >
          <div class="absolute inset-0 bg-black/50 backdrop-blur-sm" phx-click="close_create_space">
          </div>
          <div class="relative bg-base-100 rounded-lg shadow-2xl border border-base-content/[0.08] w-full max-w-md overflow-hidden">
            <div class="px-6 pt-6 pb-0">
              <div class="flex items-center gap-4 mb-1">
                <div class="w-11 h-11 rounded-xl bg-primary/10 flex items-center justify-center">
                  <.icon name="hero-folder-plus" class="size-5 text-primary" />
                </div>
                <div>
                  <h3 class="text-lg font-bold text-base-content">Create a Space</h3>
                  <p class="text-xs text-base-content/40">Isolated environment for your apps</p>
                </div>
              </div>
            </div>

            <.form
              for={@space_form}
              id="create-space-form"
              phx-change="validate_space"
              phx-submit="save_space"
              class="px-6 py-5 space-y-4"
            >
              <div>
                <.input
                  field={@space_form[:name]}
                  type="text"
                  label="Name"
                  placeholder="My Production Apps"
                  phx-blur="generate_slug"
                />
              </div>
              <div>
                <.input
                  field={@space_form[:slug]}
                  type="text"
                  label="Slug"
                  placeholder="my-production-apps"
                />
                <p class="text-[11px] text-base-content/30 mt-1.5">
                  Lowercase letters, numbers, and hyphens only.
                </p>
              </div>

              <div class="flex justify-end gap-3 pt-3 border-t border-base-content/[0.06]">
                <button
                  type="button"
                  phx-click="close_create_space"
                  class="px-4 py-2 rounded-xl text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
                >
                  Cancel
                </button>
                <button
                  type="submit"
                  class="px-5 py-2 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
                >
                  Create Space
                </button>
              </div>
            </.form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :events, :list, required: true

  defp activity_panel(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
      <div class="px-4 py-3 border-b border-base-content/[0.06] flex items-center justify-between">
        <div class="flex items-center gap-2.5">
          <div class="w-7 h-7 rounded-lg bg-warning/10 flex items-center justify-center">
            <.icon name="hero-bolt-mini" class="size-3.5 text-warning" />
          </div>
          <h2 class="text-sm font-semibold text-base-content">System Activity</h2>
        </div>
        <span class="inline-flex items-center gap-1.5 text-[11px] font-medium px-2.5 py-1 rounded-full bg-success/10 text-success">
          <span class="w-1.5 h-1.5 rounded-full bg-success"></span> Live
        </span>
      </div>

      <%= if @events == [] do %>
        <div class="px-4 py-6 text-center">
          <p class="text-sm text-base-content/30">No activity yet</p>
          <p class="text-xs text-base-content/20 mt-1">
            Events will appear here as the system operates.
          </p>
        </div>
      <% else %>
        <div class="divide-y divide-base-content/[0.04] max-h-80 overflow-y-auto">
          <div :for={event <- @events} class="px-4 py-2.5 flex items-start gap-3">
            <div class={[
              "mt-0.5 w-5 h-5 rounded-md flex items-center justify-center flex-shrink-0",
              activity_icon_bg(event.level)
            ]}>
              <.icon
                name={activity_icon(event.level)}
                class={["size-3", activity_icon_color(event.level)]}
              />
            </div>
            <div class="min-w-0 flex-1">
              <p class="text-sm text-base-content leading-snug">{event.message}</p>
              <div class="flex items-center gap-2 mt-0.5">
                <span class={[
                  "text-[10px] font-semibold uppercase tracking-wider",
                  activity_source_color(event.source)
                ]}>
                  {event.source}
                </span>
                <span class="text-[10px] text-base-content/25">
                  {relative_time(event.timestamp)}
                </span>
              </div>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp activity_icon(:error), do: "hero-x-circle-mini"
  defp activity_icon(:warn), do: "hero-exclamation-triangle-mini"
  defp activity_icon(_), do: "hero-check-circle-mini"

  defp activity_icon_bg(:error), do: "bg-error/10"
  defp activity_icon_bg(:warn), do: "bg-warning/10"
  defp activity_icon_bg(_), do: "bg-success/10"

  defp activity_icon_color(:error), do: "text-error"
  defp activity_icon_color(:warn), do: "text-warning"
  defp activity_icon_color(_), do: "text-success"

  defp activity_source_color("deploy"), do: "text-info/60"
  defp activity_source_color("docker"), do: "text-primary/60"
  defp activity_source_color("infrastructure"), do: "text-warning/60"
  defp activity_source_color("domain"), do: "text-accent/60"
  defp activity_source_color("dns"), do: "text-cyan-400/60"
  defp activity_source_color(_), do: "text-base-content/30"

  defp relative_time(nil), do: "—"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> "#{div(diff, 86400)}d ago"
    end
  end

  defp relative_time(_), do: "—"

  attr :metrics, :any, required: true
  attr :deployments, :list, required: true

  defp traffic_overview(assigns) do
    traefik = get_in(assigns.metrics || %{}, [:traefik]) || %{}
    has_traffic = map_size(traefik) > 0

    summary =
      if has_traffic do
        Enum.reduce(traefik, %{requests: 0, bytes_in: 0, bytes_out: 0, errors: 0}, fn {_svc,
                                                                                       stats},
                                                                                      acc ->
          %{
            requests: acc.requests + (stats.requests_total || 0),
            bytes_in: acc.bytes_in + (stats.requests_bytes_total || 0),
            bytes_out: acc.bytes_out + (stats.responses_bytes_total || 0),
            errors: acc.errors + (stats.error_count || 0)
          }
        end)
      else
        nil
      end

    per_deployment =
      if has_traffic do
        assigns.deployments
        |> Enum.filter(&(&1.domain && &1.domain != ""))
        |> Enum.map(fn d ->
          svc_key = sanitize_domain_key(d.domain)
          stats = find_service_stats(traefik, svc_key)
          %{name: d.app_template.name, domain: d.domain, stats: stats}
        end)
        |> Enum.filter(fn d -> d.stats.requests_total > 0 end)
      else
        []
      end

    assigns =
      assigns
      |> assign(:has_traffic, has_traffic)
      |> assign(:summary, summary)
      |> assign(:per_deployment, per_deployment)

    ~H"""
    <div
      :if={@has_traffic}
      class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden"
    >
      <div class="px-4 py-3 border-b border-base-content/[0.06] flex items-center gap-2.5">
        <div class="w-7 h-7 rounded-lg bg-accent/10 flex items-center justify-center">
          <.icon name="hero-arrow-trending-up-mini" class="size-3.5 text-accent" />
        </div>
        <h2 class="text-sm font-semibold text-base-content">Traffic</h2>
      </div>

      <div class="px-4 py-3">
        <div :if={@summary} class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-3">
          <div>
            <p class="text-xs text-base-content/40 uppercase tracking-wider">Requests</p>
            <p class="text-lg font-bold text-base-content">{format_number(@summary.requests)}</p>
          </div>
          <div>
            <p class="text-xs text-base-content/40 uppercase tracking-wider">Bandwidth In</p>
            <p class="text-lg font-bold text-base-content">{format_bytes(@summary.bytes_in)}</p>
          </div>
          <div>
            <p class="text-xs text-base-content/40 uppercase tracking-wider">Bandwidth Out</p>
            <p class="text-lg font-bold text-base-content">{format_bytes(@summary.bytes_out)}</p>
          </div>
          <div>
            <p class="text-xs text-base-content/40 uppercase tracking-wider">Errors</p>
            <p class={[
              "text-lg font-bold",
              if(@summary.errors > 0, do: "text-error", else: "text-base-content")
            ]}>
              {format_number(@summary.errors)}
            </p>
          </div>
        </div>

        <table :if={@per_deployment != []} class="w-full text-sm">
          <thead>
            <tr class="border-b border-base-content/[0.06]">
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 py-2">
                App
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 py-2">
                Requests
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 py-2">
                In
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 py-2">
                Out
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 py-2">
                Errors
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/[0.04]">
            <tr :for={d <- @per_deployment}>
              <td class="py-2">
                <p class="font-medium text-base-content">{d.name}</p>
                <p class="text-xs text-base-content/30 font-mono">{d.domain}</p>
              </td>
              <td class="py-2 text-right text-base-content/70">
                {format_number(d.stats.requests_total)}
              </td>
              <td class="py-2 text-right text-base-content/70">
                {format_bytes(d.stats.requests_bytes_total)}
              </td>
              <td class="py-2 text-right text-base-content/70">
                {format_bytes(d.stats.responses_bytes_total)}
              </td>
              <td class={[
                "py-2 text-right",
                if(d.stats.error_count > 0, do: "text-error", else: "text-base-content/70")
              ]}>
                {format_number(d.stats.error_count)}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp sanitize_domain_key(domain) do
    domain
    |> String.downcase()
    |> String.replace(".", "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp find_service_stats(traefik, svc_key) do
    case Map.get(traefik, svc_key) do
      nil ->
        Enum.find_value(
          traefik,
          %{requests_total: 0, requests_bytes_total: 0, responses_bytes_total: 0, error_count: 0},
          fn {key, stats} ->
            if String.contains?(key, svc_key), do: stats
          end
        )

      stats ->
        stats
    end
  end

  defp format_number(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_number(n) when is_number(n) and n >= 1_000, do: "#{Float.round(n / 1_000, 1)}K"
  defp format_number(n) when is_number(n), do: to_string(n)
  defp format_number(_), do: "0"

  attr :label, :string, required: true
  attr :percent, :any, required: true
  attr :detail, :string, required: true
  attr :color, :string, required: true

  defp resource_gauge(assigns) do
    clamped = min(max(assigns.percent, 0), 100)
    assigns = assign(assigns, :clamped, clamped)

    ~H"""
    <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-4">
      <div class="flex items-center justify-between mb-3">
        <p class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">{@label}</p>
        <span class={"text-sm font-bold #{value_color(@color)}"}>{format_percent(@clamped)}</span>
      </div>
      <div class="w-full h-2 rounded-full bg-base-200 overflow-hidden">
        <div
          class={[
            "h-full rounded-full transition-all duration-500",
            gauge_color(@color)
          ]}
          style={"width: #{@clamped}%"}
        >
        </div>
      </div>
      <p class="text-xs text-base-content/30 mt-2">{@detail}</p>
    </div>
    """
  end

  defp gauge_color("primary"), do: "bg-primary"
  defp gauge_color("info"), do: "bg-info"
  defp gauge_color("success"), do: "bg-success"
  defp gauge_color("error"), do: "bg-error"
  defp gauge_color(_), do: "bg-base-content/30"

  attr :label, :string, required: true
  attr :value, :integer, required: true
  attr :icon, :string, required: true
  attr :color, :string, required: true
  attr :description, :string, default: nil

  defp stat_card(assigns) do
    ~H"""
    <div class="group rounded-lg border border-base-content/[0.06] bg-base-100 p-4 hover:border-base-content/[0.1] transition-colors duration-200">
      <div class="flex items-center justify-between mb-3">
        <p class="text-xs font-semibold text-base-content/40 uppercase tracking-wider">
          {@label}
        </p>
        <div class={"w-9 h-9 rounded-xl #{icon_bg(@color)} flex items-center justify-center"}>
          <.icon name={@icon} class={"size-4 #{icon_color(@color)}"} />
        </div>
      </div>
      <p class={"text-3xl font-extrabold tracking-tight #{value_color(@color)}"}>{@value}</p>
      <p :if={@description} class="text-xs text-base-content/30 mt-1">{@description}</p>
    </div>
    """
  end

  defp value_color("primary"), do: "text-base-content"
  defp value_color("info"), do: "text-base-content"
  defp value_color("success"), do: "text-success"
  defp value_color("error"), do: "text-error"
  defp value_color(_), do: "text-base-content"

  defp icon_bg("primary"), do: "bg-primary/10"
  defp icon_bg("info"), do: "bg-info/10"
  defp icon_bg("success"), do: "bg-success/10"
  defp icon_bg("error"), do: "bg-error/10"
  defp icon_bg(_), do: "bg-base-200"

  defp icon_color("primary"), do: "text-primary"
  defp icon_color("info"), do: "text-info"
  defp icon_color("success"), do: "text-success"
  defp icon_color("error"), do: "text-error"
  defp icon_color(_), do: "text-base-content/40"

  defp status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-medium px-2.5 py-1 rounded-full",
      pill_classes(@status)
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", dot_color(@status)]}></span>
      {format_status(@status)}
    </span>
    """
  end

  defp pill_classes(:active), do: "bg-success/10 text-success"
  defp pill_classes(:running), do: "bg-success/10 text-success"
  defp pill_classes(:pending), do: "bg-warning/10 text-warning"
  defp pill_classes(:deploying), do: "bg-info/10 text-info"
  defp pill_classes(:failed), do: "bg-error/10 text-error"
  defp pill_classes(:stopped), do: "bg-base-200 text-base-content/50"
  defp pill_classes(:suspended), do: "bg-warning/10 text-warning"
  defp pill_classes(:archived), do: "bg-base-200 text-base-content/40"
  defp pill_classes(:removing), do: "bg-error/10 text-error"
  defp pill_classes(_), do: "bg-base-200 text-base-content/50"

  defp dot_color(:active), do: "bg-success"
  defp dot_color(:running), do: "bg-success"
  defp dot_color(:pending), do: "bg-warning"
  defp dot_color(:deploying), do: "bg-info"
  defp dot_color(:failed), do: "bg-error"
  defp dot_color(_), do: "bg-base-content/30"

  defp format_status(:active), do: "Active"
  defp format_status(:running), do: "Running"
  defp format_status(:pending), do: "Pending"
  defp format_status(:deploying), do: "Deploying"
  defp format_status(:failed), do: "Failed"
  defp format_status(:stopped), do: "Stopped"
  defp format_status(:suspended), do: "Suspended"
  defp format_status(:archived), do: "Archived"
  defp format_status(:removing), do: "Removing"
  defp format_status(status), do: to_string(status)

  defp format_percent(nil), do: "—"
  defp format_percent(n) when is_number(n), do: "#{Float.round(n * 1.0, 1)}%"

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp docker_containers_running(metrics) do
    case metrics do
      %{docker: %{"Containers" => c, "ContainersRunning" => r}} ->
        "#{r}/#{c}"

      _ ->
        "—"
    end
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end
end
