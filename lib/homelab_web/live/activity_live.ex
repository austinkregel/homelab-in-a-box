defmodule HomelabWeb.ActivityLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Audit

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()
    activities = Audit.list_recent(100)

    socket =
      socket
      |> assign(:page_title, "Activity")
      |> assign(:tenants, tenants)
      |> assign(:activities, activities)

    {:ok, socket}
  end

  defp action_icon("deployment.created"), do: "hero-rocket-launch"
  defp action_icon("deployment.stopped"), do: "hero-stop"
  defp action_icon("deployment.started"), do: "hero-play"
  defp action_icon("backup.created"), do: "hero-archive-box"
  defp action_icon(_), do: "hero-bolt"

  defp format_relative_time(datetime) do
    diff_sec = DateTime.diff(DateTime.utc_now(), datetime, :second)

    cond do
      diff_sec < 60 -> "just now"
      diff_sec < 3600 -> "#{div(diff_sec, 60)}m ago"
      diff_sec < 86400 -> "#{div(diff_sec, 3600)}h ago"
      diff_sec < 604_800 -> "#{div(diff_sec, 86400)}d ago"
      true -> Calendar.strftime(datetime, "%b %d, %Y")
    end
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
      <div class="space-y-10">
        <%!-- Page header --%>
        <div class="relative overflow-hidden rounded-lg bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-8">
          <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl"></div>
          <div class="relative">
            <div class="flex items-center gap-3 mb-2">
              <div class="w-10 h-10 rounded-lg bg-primary/20 flex items-center justify-center">
                <.icon name="hero-clock-solid" class="size-5 text-primary" />
              </div>
              <h1 class="text-2xl font-bold text-base-content tracking-tight">Activity Log</h1>
            </div>
            <p class="text-sm text-base-content/50 max-w-lg leading-relaxed mt-1">
              Recent activity across your homelab. Track deployments, backups, and system changes.
            </p>
          </div>
        </div>

        <%!-- Activity timeline --%>
        <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
          <div :if={@activities == []} class="px-6 py-16 text-center">
            <div class="mx-auto w-14 h-14 rounded-lg bg-base-200/80 flex items-center justify-center mb-4">
              <.icon name="hero-bolt" class="size-6 text-base-content/20" />
            </div>
            <p class="text-sm font-medium text-base-content/60 mb-1">No activity yet</p>
            <p class="text-xs text-base-content/35 leading-relaxed max-w-[280px] mx-auto">
              Activity will appear here as you deploy apps and perform actions.
            </p>
          </div>

          <div :if={@activities != []} class="divide-y divide-base-content/[0.04]">
            <div
              :for={activity <- @activities}
              class="flex items-start gap-4 px-4 py-3 hover:bg-base-content/[0.02] transition-colors"
            >
              <div class="w-9 h-9 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0 mt-0.5">
                <.icon name={action_icon(activity.action)} class="size-4 text-primary" />
              </div>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium text-base-content">
                  {format_action(activity.action)}
                </p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  {activity.resource_type}
                  <span :if={activity.resource_id}> #{activity.resource_id}</span>
                  <span :if={activity.user}>
                    &middot; {activity.user.email}
                  </span>
                </p>
              </div>
              <span class="text-xs text-base-content/35 flex-shrink-0">
                {format_relative_time(activity.inserted_at)}
              </span>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_action(action) when is_binary(action) do
    action
    |> String.replace(".", " ")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map(&String.capitalize/1)
    |> Enum.join(" ")
  end

  defp format_action(action), do: to_string(action)
end
