defmodule HomelabWeb.AppsLive do
  @moduledoc """
  Every deployment on the box, in one list.

  The app had no such page. A deployment could be reached from its space, or from
  the first ten rows of the Dashboard, which meant the most-repeated question an
  operator has — "where is the app I am thinking about" — had no reliable answer
  past ten apps.

  Filtering happens in memory rather than in the query. A homelab holds tens of
  deployments, not thousands, and the list is already fully loaded and preloaded
  to render the rows.
  """
  use HomelabWeb, :live_view

  alias Homelab.Deployments
  alias Homelab.Tenants

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: :timer.send_interval(5000, self(), :refresh)

    {:ok,
     socket
     |> assign(:page_title, "Apps")
     |> assign(:tenants, Tenants.list_active_tenants())
     |> assign(:query, "")
     |> assign(:space_id, nil)
     |> load_deployments()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    space_id =
      case Integer.parse(params["space"] || "") do
        {id, ""} -> id
        _ -> nil
      end

    {:noreply,
     socket
     |> assign(:query, params["q"] || "")
     |> assign(:space_id, space_id)}
  end

  @impl true
  def handle_info(:refresh, socket), do: {:noreply, load_deployments(socket)}

  @impl true
  def handle_event("search", %{"q" => q}, socket) do
    {:noreply, push_patch(socket, to: path_for(q, socket.assigns.space_id))}
  end

  def handle_event("filter_space", %{"id" => id}, socket) do
    space_id = if id == "", do: nil, else: String.to_integer(id)
    {:noreply, push_patch(socket, to: path_for(socket.assigns.query, space_id))}
  end

  def handle_event("start", %{"id" => id}, socket),
    do: act(socket, id, &Deployments.start_deployment/1, "starting")

  def handle_event("stop", %{"id" => id}, socket),
    do: act(socket, id, &Deployments.stop_deployment/1, "stopped")

  def handle_event("restart", %{"id" => id}, socket),
    do: act(socket, id, &Deployments.restart_deployment/1, "restarting")

  defp act(socket, id, fun, verb) do
    deployment = Deployments.get_deployment!(String.to_integer(id))

    socket =
      case fun.(deployment) do
        {:ok, _} ->
          put_flash(socket, :info, "#{deployment.app_template.name} #{verb}.")

        {:error, _} ->
          put_flash(socket, :error, "Could not #{verb} #{deployment.app_template.name}.")
      end

    {:noreply, load_deployments(socket)}
  end

  defp path_for(query, space_id) do
    params =
      %{}
      |> maybe_put("q", query)
      |> maybe_put("space", space_id && to_string(space_id))

    ~p"/apps?#{params}"
  end

  defp maybe_put(params, _key, value) when value in [nil, ""], do: params
  defp maybe_put(params, key, value), do: Map.put(params, key, value)

  defp load_deployments(socket), do: assign(socket, :deployments, Deployments.list_deployments())

  # `list_deployments/0` already sorts by attention, so filtering preserves it.
  defp visible(deployments, query, space_id) do
    deployments
    |> Enum.filter(&(space_id == nil or &1.tenant_id == space_id))
    |> Enum.filter(&matches?(&1, String.trim(query)))
  end

  defp matches?(_deployment, ""), do: true

  defp matches?(deployment, query) do
    q = String.downcase(query)

    [
      deployment.app_template && deployment.app_template.name,
      deployment.app_template && deployment.app_template.image,
      deployment.tenant && deployment.tenant.name,
      deployment.domain,
      to_string(deployment.status)
    ]
    |> Enum.any?(fn field -> is_binary(field) and String.contains?(String.downcase(field), q) end)
  end

  @impl true
  def render(assigns) do
    assigns =
      assign(assigns, :visible, visible(assigns.deployments, assigns.query, assigns.space_id))

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
        <div class="flex items-start justify-between gap-6">
          <div>
            <h1 class="text-2xl font-bold text-base-content tracking-tight">Apps</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Every deployment across every space. Whatever needs attention sorts first.
            </p>
          </div>
          <.link
            navigate={~p"/catalog"}
            class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            <.icon name="hero-plus-mini" class="size-4" /> Deploy an app
          </.link>
        </div>

        <div class="flex flex-wrap items-center gap-3">
          <form phx-change="search" phx-submit="search" class="flex-1 min-w-[220px]">
            <div class="relative">
              <.icon
                name="hero-magnifying-glass-mini"
                class="size-4 text-base-content/30 absolute left-3 top-1/2 -translate-y-1/2"
              />
              <input
                type="text"
                name="q"
                value={@query}
                placeholder="Search apps, images, spaces, domains…"
                autocomplete="off"
                phx-debounce="150"
                class="w-full rounded-lg bg-base-100 border border-base-content/10 text-sm py-2 pl-9 pr-3 focus:ring-2 focus:ring-primary/40 focus:border-primary/40"
              />
            </div>
          </form>
        </div>

        <div class="flex flex-wrap items-center gap-1.5">
          <button
            type="button"
            phx-click="filter_space"
            phx-value-id=""
            class={chip_classes(@space_id == nil)}
          >
            All spaces
          </button>
          <button
            :for={tenant <- @tenants}
            type="button"
            phx-click="filter_space"
            phx-value-id={tenant.id}
            class={chip_classes(@space_id == tenant.id)}
          >
            {tenant.name}
          </button>
        </div>

        <div
          :if={@visible == []}
          class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-16 text-center"
        >
          <div class="mx-auto w-14 h-14 rounded-lg bg-base-200/80 flex items-center justify-center mb-4">
            <.icon name="hero-cube" class="size-6 text-base-content/20" />
          </div>
          <p class="text-sm font-medium text-base-content/60 mb-1">
            {if @deployments == [], do: "No apps yet", else: "Nothing matches"}
          </p>
          <p class="text-xs text-base-content/35">
            {if @deployments == [],
              do: "Deploy something from the catalog to see it here.",
              else: "Try a different search, or clear the space filter."}
          </p>
        </div>

        <div :if={@visible != []} class="space-y-2">
          <div
            :for={deployment <- @visible}
            class="rounded-lg bg-base-100 border border-base-content/[0.06] hover:border-base-content/[0.12] transition-colors"
          >
            <div class="flex items-center gap-4 p-4">
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

              <.link
                navigate={~p"/spaces/#{deployment.tenant_id}"}
                class="hidden md:flex items-center gap-1.5 text-xs text-base-content/40 hover:text-base-content/70 transition-colors flex-shrink-0"
              >
                <.icon name="hero-folder-solid" class="size-3.5 opacity-60" />
                {deployment.tenant.name}
              </.link>

              <div class="text-right hidden sm:block flex-shrink-0">
                <span :if={deployment.domain} class="text-xs text-base-content/50 font-mono">
                  {deployment.domain}
                </span>
                <p class="text-[11px] text-base-content/25 mt-0.5">
                  {relative_time(deployment.last_reconciled_at)}
                </p>
              </div>

              <.status_pill status={deployment.status} />

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
              </div>
            </div>

            <p
              :if={deployment.status == :failed && deployment.error_message}
              class="px-4 pb-3 -mt-1 text-xs text-error/80 font-mono truncate"
            >
              {deployment.error_message}
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp chip_classes(active?) do
    [
      "px-3 py-1.5 rounded-full text-xs font-medium transition-colors cursor-pointer",
      if(active?,
        do: "bg-primary/15 text-primary",
        else:
          "bg-base-100 text-base-content/50 hover:text-base-content border border-base-content/[0.08]"
      )
    ]
  end

  attr :status, :atom, required: true

  defp status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-medium px-2.5 py-1 rounded-full flex-shrink-0",
      pill_classes(@status)
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", dot_color(@status)]}></span>
      {format_status(@status)}
    </span>
    """
  end

  defp pill_classes(:running), do: "bg-success/10 text-success"
  defp pill_classes(:pending), do: "bg-warning/10 text-warning"
  defp pill_classes(:deploying), do: "bg-info/10 text-info"
  defp pill_classes(:failed), do: "bg-error/10 text-error"
  defp pill_classes(:removing), do: "bg-error/10 text-error"
  defp pill_classes(_), do: "bg-base-200 text-base-content/50"

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
