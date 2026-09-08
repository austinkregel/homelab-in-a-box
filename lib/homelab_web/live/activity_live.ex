defmodule HomelabWeb.ActivityLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Audit
  alias Homelab.Deployments

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()
    activities = Audit.list_recent(100)

    socket =
      socket
      |> assign(:page_title, "Activity")
      |> assign(:tenants, tenants)
      |> assign(:activities, activities)
      |> assign(:subjects, subjects_for(activities))

    {:ok, socket}
  end

  # The deployments these entries are ABOUT, resolved once for the page.
  #
  # Every writer already passes `deployment_id` in the metadata, and the row it produced
  # rendered as "deploy #98" — an internal id, on the one page whose whole job is to say
  # what happened to what. One query for a hundred rows.
  defp subjects_for(activities) do
    activities
    |> Enum.flat_map(&List.wrap(subject_id(&1)))
    |> Enum.uniq()
    |> Deployments.by_ids()
  end

  defp subject_id(%{metadata: %{"deployment_id" => id}}) when is_integer(id), do: id

  defp subject_id(%{metadata: %{"deployment_id" => id}}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp subject_id(_activity), do: nil

  # What actually happened, in the words the writer used. `ActivityLog.push/4` has always
  # carried a written message — "Sonarr deployed", "gluetun: the container whose network
  # it shares was replaced" — and `persist_to_audit/4` files it under `metadata.message`,
  # where this page was not looking. It rendered the ACTION instead, so a hundred distinct
  # events collapsed into a wall of "Deploy Info" over "deploy #98".
  #
  # Rows written straight through `Audit.log/4` carry no message; those still fall back to
  # the humanized action, which for them is the whole of what is known.
  defp message(%{metadata: %{"message" => message}}) when is_binary(message) and message != "",
    do: message

  defp message(activity), do: format_action(activity.action)

  # `ActivityLog` writes `"<source>.<level>"`. The level decides the colour, because an
  # error and a routine info line were previously the same purple bolt — the page showed
  # that something failed only if you read the sentence it was not printing.
  defp level(%{action: action}) when is_binary(action) do
    case action |> String.split(".") |> List.last() do
      "error" -> :error
      "warn" -> :warn
      _ -> :info
    end
  end

  defp level(_activity), do: :info

  defp level_classes(:error), do: {"bg-error/10", "text-error"}
  defp level_classes(:warn), do: {"bg-warning/10", "text-warning"}
  defp level_classes(:info), do: {"bg-primary/10", "text-primary"}

  defp action_icon(%{action: action} = activity) when is_binary(action) do
    case level(activity) do
      :error -> "hero-exclamation-triangle"
      :warn -> "hero-exclamation-circle"
      :info -> source_icon(action |> String.split(".") |> List.first())
    end
  end

  defp action_icon(_activity), do: "hero-bolt"

  defp source_icon("deploy"), do: "hero-rocket-launch"
  defp source_icon("deployment"), do: "hero-rocket-launch"
  defp source_icon("backup"), do: "hero-archive-box"
  defp source_icon("dns"), do: "hero-globe-alt"
  defp source_icon("domain"), do: "hero-globe-alt"
  defp source_icon("reconciler"), do: "hero-arrow-path"
  defp source_icon(_source), do: "hero-bolt"

  # The trail under the message: where it came from, and which deployment it is about by
  # NAME. Falls back to the raw resource only when the id resolves to nothing — a row
  # about a deployment that has since been deleted still says what it can.
  defp context_line(activity, subjects) do
    [source_label(activity), subject_label(activity, subjects)]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
  end

  defp source_label(%{action: action}) when is_binary(action),
    do: action |> String.split(".") |> List.first() |> format_action()

  defp source_label(%{resource_type: type}), do: type

  defp subject_label(activity, subjects) do
    case Map.get(subjects, subject_id(activity)) do
      %{app_template: %{name: name}} when is_binary(name) and name != "" -> name
      %{app_template: %{slug: slug}} when is_binary(slug) and slug != "" -> slug
      _ -> fallback_subject(activity)
    end
  end

  defp fallback_subject(%{resource_id: id}) when is_integer(id), do: "##{id}"
  defp fallback_subject(_activity), do: nil

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
      notification_count={@notification_count}
      notifications={@notifications}
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
              <% {icon_bg, icon_fg} = level_classes(level(activity)) %>
              <div class={[
                "w-9 h-9 rounded-lg flex items-center justify-center flex-shrink-0 mt-0.5",
                icon_bg
              ]}>
                <.icon name={action_icon(activity)} class={["size-4", icon_fg]} />
              </div>
              <div class="min-w-0 flex-1">
                <p class="text-sm font-medium text-base-content break-words">
                  {message(activity)}
                </p>
                <p class="text-xs text-base-content/50 mt-0.5">
                  {context_line(activity, @subjects)}
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
