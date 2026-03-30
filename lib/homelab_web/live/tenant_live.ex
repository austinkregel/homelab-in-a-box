defmodule HomelabWeb.TenantLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Deployments

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    case Tenants.get_tenant(String.to_integer(id)) do
      {:ok, tenant} ->
        if connected?(socket), do: :timer.send_interval(5000, self(), :refresh)

        deployments = Deployments.list_deployments_for_tenant(tenant.id)
        all_tenants = Tenants.list_tenants()

        counts =
          Enum.group_by(deployments, & &1.status)
          |> Map.new(fn {status, deps} -> {status, length(deps)} end)

        socket =
          socket
          |> assign(:page_title, tenant.name)
          |> assign(:tenant, tenant)
          |> assign(:tenants, all_tenants)
          |> assign(:deployments, deployments)
          |> assign(:counts, counts)

        {:ok, socket}

      {:error, :not_found} ->
        {:ok,
         socket
         |> put_flash(:error, "Tenant not found")
         |> redirect(to: ~p"/")}
    end
  end

  @impl true
  def handle_info(:refresh, socket) do
    deployments = Deployments.list_deployments_for_tenant(socket.assigns.tenant.id)

    counts =
      Enum.group_by(deployments, & &1.status)
      |> Map.new(fn {status, deps} -> {status, length(deps)} end)

    {:noreply,
     socket
     |> assign(:deployments, deployments)
     |> assign(:counts, counts)}
  end

  @impl true
  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    deployment = Deployments.get_deployment!(String.to_integer(id))

    case Deployments.stop_deployment(deployment) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "#{deployment.app_template.name} stopped.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to stop.")}
    end
  end

  def handle_event("start", %{"id" => id}, socket) do
    deployment = Deployments.get_deployment!(String.to_integer(id))

    case Deployments.start_deployment(deployment) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "#{deployment.app_template.name} starting.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start.")}
    end
  end

  def handle_event("restart", %{"id" => id}, socket) do
    deployment = Deployments.get_deployment!(String.to_integer(id))

    case Deployments.restart_deployment(deployment) do
      {:ok, _} -> {:noreply, put_flash(socket, :info, "#{deployment.app_template.name} restarting.")}
      {:error, _} -> {:noreply, put_flash(socket, :error, "Failed to restart.")}
    end
  end

  def handle_event("delete", %{"id" => id}, socket) do
    deployment = Deployments.get_deployment!(String.to_integer(id))
    Deployments.destroy_deployment(deployment)

    {:noreply,
     socket
     |> put_flash(:info, "#{deployment.app_template.name} deleted.")
     |> assign(:deployments, Deployments.list_deployments_for_tenant(socket.assigns.tenant.id))}
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
        <div class="flex items-center gap-2 text-sm text-base-content/40">
          <.link navigate={~p"/"} class="hover:text-base-content/70 transition-colors">
            Dashboard
          </.link>
          <.icon name="hero-chevron-right-mini" class="size-3.5" />
          <span class="text-base-content/60">{@tenant.name}</span>
        </div>

        <div class="flex items-center justify-between">
          <div class="flex items-center gap-5">
            <div class="w-14 h-14 rounded-lg bg-primary/10 flex items-center justify-center">
              <.icon name="hero-folder-solid" class="size-7 text-primary" />
            </div>
            <div>
              <h1 class="text-2xl font-bold text-base-content">{@tenant.name}</h1>
              <p class="text-sm text-base-content/40 font-mono">{@tenant.slug}</p>
            </div>
          </div>
          <.link
            navigate={~p"/catalog"}
            class="flex items-center gap-2 px-4 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 hover:-translate-y-0.5 transition-all duration-200"
          >
            <.icon name="hero-plus-mini" class="size-4" /> Deploy App
          </.link>
        </div>

        <%!-- Summary cards --%>
        <div class="grid grid-cols-2 md:grid-cols-4 gap-3">
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-3">
            <p class="text-xs font-semibold text-base-content/40 uppercase tracking-wider mb-1">
              Total
            </p>
            <p class="text-2xl font-bold text-base-content">{length(@deployments)}</p>
          </div>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-3">
            <p class="text-xs font-semibold text-success/60 uppercase tracking-wider mb-1">Running</p>
            <p class="text-2xl font-bold text-success">{Map.get(@counts, :running, 0)}</p>
          </div>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-3">
            <p class="text-xs font-semibold text-warning/60 uppercase tracking-wider mb-1">Pending</p>
            <p class="text-2xl font-bold text-warning">
              {Map.get(@counts, :pending, 0) + Map.get(@counts, :deploying, 0)}
            </p>
          </div>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-3">
            <p class="text-xs font-semibold text-error/60 uppercase tracking-wider mb-1">Failed</p>
            <p class="text-2xl font-bold text-error">{Map.get(@counts, :failed, 0)}</p>
          </div>
        </div>

        <%!-- Infrastructure topology --%>
        <div :if={@deployments != []} class="space-y-2">
          <div class="flex items-center gap-2">
            <.icon name="hero-squares-2x2" class="size-4 text-base-content/30" />
            <h2 class="text-sm font-semibold text-base-content/50">Infrastructure Topology</h2>
          </div>
          <% topo = HomelabWeb.Topology.from_tenant(@deployments) %>
          <.topology nodes={topo.nodes} edges={topo.edges} />
        </div>

        <%!-- Deployments --%>
        <div
          :if={@deployments == []}
          class="rounded-lg bg-base-100 border border-base-content/[0.06] p-8 text-center"
        >
          <div class="mx-auto w-16 h-16 rounded-full bg-base-200 flex items-center justify-center mb-5">
            <.icon name="hero-cube" class="size-8 text-base-content/20" />
          </div>
          <p class="font-medium text-base-content/50">No apps deployed yet.</p>
          <p class="text-sm text-base-content/30 mt-1.5 mb-4">
            Visit the catalog to deploy your first app to this space.
          </p>
          <.link
            navigate={~p"/catalog"}
            class="inline-flex items-center gap-1.5 text-sm font-semibold text-primary hover:text-primary/80 transition-colors"
          >
            <.icon name="hero-arrow-right-mini" class="size-4" /> Browse Catalog
          </.link>
        </div>

        <div :if={@deployments != []} class="space-y-3">
          <div
            :for={deployment <- @deployments}
            class="rounded-lg bg-base-100 border border-base-content/[0.06] overflow-hidden hover:border-base-content/[0.12] transition-colors"
          >
            <div class="flex items-center gap-4 p-4">
              <%!-- App icon + name --%>
              <.link
                navigate={~p"/deployments/#{deployment.id}"}
                class="flex items-center gap-4 flex-1 min-w-0"
              >
                <div class="w-11 h-11 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0 overflow-hidden">
                  <img
                    :if={deployment.app_template.logo_url}
                    src={deployment.app_template.logo_url}
                    alt=""
                    class="w-full h-full object-contain"
                  />
                  <.icon
                    :if={!deployment.app_template.logo_url}
                    name="hero-cube-solid"
                    class="size-5 text-primary"
                  />
                </div>
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-base-content truncate">
                    {deployment.app_template.name}
                  </p>
                  <p class="text-xs text-base-content/35 font-mono truncate">
                    {deployment.app_template.image}
                  </p>
                </div>
              </.link>

              <%!-- Status + domain --%>
              <div class="flex items-center gap-4 flex-shrink-0">
                <div class="text-right hidden sm:block">
                  <span
                    :if={deployment.domain}
                    class="text-xs text-base-content/50 font-mono"
                  >
                    {deployment.domain}
                  </span>
                  <p class="text-[11px] text-base-content/25 mt-0.5">
                    {relative_time(deployment.last_reconciled_at)}
                  </p>
                </div>
                <.status_pill status={deployment.status} />
              </div>

              <%!-- Quick actions --%>
              <div class="flex items-center gap-1 flex-shrink-0">
                <button
                  :if={deployment.status in [:stopped, :failed]}
                  type="button"
                  phx-click="start"
                  phx-value-id={deployment.id}
                  title="Start"
                  class="w-8 h-8 rounded-lg flex items-center justify-center text-success hover:bg-success/10 transition-colors cursor-pointer"
                >
                  <.icon name="hero-play-mini" class="size-4" />
                </button>
                <button
                  :if={deployment.status == :running}
                  type="button"
                  phx-click="stop"
                  phx-value-id={deployment.id}
                  title="Stop"
                  class="w-8 h-8 rounded-lg flex items-center justify-center text-warning hover:bg-warning/10 transition-colors cursor-pointer"
                >
                  <.icon name="hero-stop-mini" class="size-4" />
                </button>
                <button
                  :if={deployment.status == :running && deployment.external_id}
                  type="button"
                  phx-click="restart"
                  phx-value-id={deployment.id}
                  title="Restart"
                  class="w-8 h-8 rounded-lg flex items-center justify-center text-info hover:bg-info/10 transition-colors cursor-pointer"
                >
                  <.icon name="hero-arrow-path-mini" class="size-4" />
                </button>
                <.link
                  navigate={~p"/deployments/#{deployment.id}"}
                  title="Details"
                  class="w-8 h-8 rounded-lg flex items-center justify-center text-base-content/40 hover:text-base-content hover:bg-base-content/5 transition-colors"
                >
                  <.icon name="hero-chevron-right-mini" class="size-4" />
                </.link>
              </div>
            </div>

            <%!-- Error banner for failed deployments --%>
            <div
              :if={deployment.status == :failed && deployment.error_message}
              class="px-5 py-2.5 bg-error/5 border-t border-error/10 flex items-start gap-2"
            >
              <.icon
                name="hero-exclamation-circle-mini"
                class="size-4 text-error flex-shrink-0 mt-0.5"
              />
              <p class="text-xs text-error/80 leading-relaxed">{deployment.error_message}</p>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

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
  defp pill_classes(:removing), do: "bg-error/10 text-error"
  defp pill_classes(_), do: "bg-base-200 text-base-content/50"

  defp dot_color(:active), do: "bg-success"
  defp dot_color(:running), do: "bg-success"
  defp dot_color(:pending), do: "bg-warning"
  defp dot_color(:deploying), do: "bg-info"
  defp dot_color(:failed), do: "bg-error"
  defp dot_color(_), do: "bg-base-content/30"

  defp format_status(:running), do: "Running"
  defp format_status(:pending), do: "Pending"
  defp format_status(:deploying), do: "Deploying"
  defp format_status(:failed), do: "Failed"
  defp format_status(:stopped), do: "Stopped"
  defp format_status(:removing), do: "Removing"
  defp format_status(status), do: to_string(status)

  defp relative_time(nil), do: "never reconciled"

  defp relative_time(%DateTime{} = dt) do
    diff = DateTime.diff(DateTime.utc_now(), dt, :second)

    cond do
      diff < 5 -> "just now"
      diff < 60 -> "#{diff}s ago"
      diff < 3600 -> "#{div(diff, 60)}m ago"
      diff < 86400 -> "#{div(diff, 3600)}h ago"
      true -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
    end
  end

  defp relative_time(_), do: "—"
end
