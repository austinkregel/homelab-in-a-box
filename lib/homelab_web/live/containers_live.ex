defmodule HomelabWeb.ContainersLive do
  @moduledoc """
  Every container on the daemon — including the ones this app does not manage.

  Nothing else in the UI shows these. Both orchestrator drivers list services with a
  server-side `label=homelab.managed=true` filter, so an unmanaged container is not
  merely unlisted, it is *invisible*: it cannot appear in a stale cache or a slow refresh
  because the daemon never sent it. The only unfiltered read in the codebase is the
  adoption scan, and that one narrows again to `in_scope` before it reaches a screen.

  That second narrowing is what this page exists for. `discover_in_scope/0` keeps only
  containers with a bind under the adoption root, which is the right filter for *what
  should I import* and the wrong one for *what is running on my box*. A container with
  no in-root bind — a named-volume-only stack, something started by hand, a stray
  `docker run` — is unmanaged, invisible, and holding ports and disk. It shows up here.

  Scope is shown, not enforced: out-of-scope containers are listed and labelled, with
  the reason they were skipped, rather than filtered out again one layer further down.
  """

  use HomelabWeb, :live_view

  alias Homelab.Deployments.{AdoptionDiscovery, AdoptionPolicy}
  alias Homelab.Tenants

  @tabs ~w(unmanaged managed all)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Containers")
      |> assign(:tenants, Tenants.list_active_tenants())
      |> assign(:active_tab, "unmanaged")
      |> assign(:expanded, nil)
      |> assign(:loading, true)
      |> assign(:containers, [])
      |> assign(:error, nil)

    # The scan inspects every container one by one, so it is far too slow for mount.
    # Render the shell first and fill it in.
    if connected?(socket), do: send(self(), :scan)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "unmanaged"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_info(:scan, socket) do
    {:noreply, scan(socket)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> assign(:expanded, nil)
     |> push_patch(to: ~p"/containers?tab=#{tab}")}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply, socket |> assign(:loading, true) |> assign(:expanded, nil) |> scan()}
  end

  def handle_event("toggle", %{"id" => id}, socket) do
    {:noreply, assign(socket, :expanded, if(socket.assigns.expanded == id, do: nil, else: id))}
  end

  defp scan(socket) do
    case safe_discover() do
      {:ok, containers} ->
        socket
        |> assign(:containers, Enum.sort_by(containers, &String.downcase(&1.name)))
        |> assign(:loading, false)
        |> assign(:error, nil)

      {:error, reason} ->
        socket
        |> assign(:containers, [])
        |> assign(:loading, false)
        |> assign(:error, reason)
    end
  end

  # `discover/0` talks to the daemon on every call. An unreachable socket should read as
  # "Docker is unreachable", not a crashed LiveView that takes the sidebar with it — and
  # `with` in `discover/0` passes a `{:error, _}` straight through, so both the returned
  # failure and an outright raise have to land somewhere.
  defp safe_discover do
    case AdoptionDiscovery.discover() do
      {:ok, containers} -> {:ok, containers}
      {:error, reason} -> {:error, "the Docker daemon refused the request: #{inspect(reason)}"}
      other -> {:error, "the Docker daemon answered with #{inspect(other)}"}
    end
  rescue
    error -> {:error, Exception.message(error)}
  catch
    :exit, reason -> {:error, "the Docker daemon did not answer (#{inspect(reason)})"}
  end

  # --- derived views -------------------------------------------------------

  defp visible(containers, "unmanaged"), do: Enum.reject(containers, & &1.managed)
  defp visible(containers, "managed"), do: Enum.filter(containers, & &1.managed)
  defp visible(containers, _all), do: containers

  defp count(containers, tab), do: containers |> visible(tab) |> length()

  # Why the adoption scan would skip this container. Only meaningful for unmanaged ones —
  # a managed container is out of scope because we already own it, which is not a reason
  # worth printing next to it.
  defp skip_reason(%{managed: true}), do: nil
  defp skip_reason(%{in_scope: true}), do: nil

  defp skip_reason(container) do
    if Enum.any?(container.mounts, &(&1.type == "bind")) do
      "no folder mount under #{AdoptionPolicy.adoption_root()}"
    else
      "no folder mounts at all — named volumes only"
    end
  end

  defp state_tone("running"), do: "bg-success/15 text-success"
  defp state_tone("exited"), do: "bg-base-content/10 text-base-content/50"
  defp state_tone("created"), do: "bg-info/15 text-info"
  defp state_tone("restarting"), do: "bg-warning/15 text-warning"
  defp state_tone("paused"), do: "bg-warning/15 text-warning"
  defp state_tone(_), do: "bg-base-content/10 text-base-content/50"

  defp short_id(nil), do: "—"
  defp short_id(id), do: String.slice(id, 0, 12)

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
      <div class="space-y-8">
        <%!-- Page header --%>
        <div class="relative overflow-hidden rounded-lg bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-8">
          <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl"></div>
          <div class="relative flex items-start justify-between gap-6">
            <div>
              <div class="flex items-center gap-3 mb-2">
                <div class="w-10 h-10 rounded-lg bg-primary/20 flex items-center justify-center">
                  <.icon name="hero-cube-solid" class="size-5 text-primary" />
                </div>
                <h1 class="text-2xl font-bold text-base-content tracking-tight">Containers</h1>
              </div>
              <p class="text-sm text-base-content/50 max-w-2xl">
                Everything running on the Docker daemon, whether or not this app put it there.
                Containers without the <code class="text-xs">homelab.managed</code>
                label are invisible to the rest of the UI.
              </p>
            </div>
            <button
              type="button"
              phx-click="refresh"
              disabled={@loading}
              class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-base-100 border border-base-content/10 text-sm font-medium hover:bg-base-content/5 disabled:opacity-40 cursor-pointer"
            >
              <.icon name="hero-arrow-path" class={["size-4", @loading && "animate-spin"]} /> Rescan
            </button>
          </div>
        </div>

        <div :if={@error} class="rounded-lg border border-error/20 bg-error/5 px-5 py-4">
          <div class="flex items-start gap-3">
            <.icon name="hero-exclamation-triangle" class="size-5 text-error shrink-0 mt-0.5" />
            <div>
              <p class="text-sm font-medium text-error">Could not read the daemon</p>
              <p class="text-xs text-base-content/50 mt-1">{@error}</p>
            </div>
          </div>
        </div>

        <%!-- Tabs --%>
        <div class="flex items-center gap-1 rounded-xl bg-base-200/60 p-1 w-fit">
          <button
            :for={tab <- ~w(unmanaged managed all)}
            type="button"
            phx-click="switch_tab"
            phx-value-tab={tab}
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-all duration-200 cursor-pointer",
              if(@active_tab == tab,
                do: "bg-base-100 text-base-content shadow-sm",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            {tab_label(tab)}
            <span class="ml-1.5 text-xs opacity-50">{count(@containers, tab)}</span>
          </button>
        </div>

        <div
          :if={@loading}
          class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-12 text-center"
        >
          <.icon name="hero-arrow-path" class="size-6 text-base-content/20 animate-spin mx-auto" />
          <p class="text-sm text-base-content/40 mt-3">
            Inspecting every container on the daemon…
          </p>
        </div>

        <div :if={not @loading} class="space-y-4">
          <%!-- Importable callout, unmanaged tab only --%>
          <div
            :if={@active_tab == "unmanaged" and importable(@containers) != []}
            class="rounded-lg border border-primary/20 bg-primary/5 px-5 py-4"
          >
            <div class="flex items-start justify-between gap-4">
              <div class="flex items-start gap-3">
                <.icon name="hero-arrow-down-tray" class="size-5 text-primary shrink-0 mt-0.5" />
                <div>
                  <p class="text-sm font-medium text-base-content">
                    {length(importable(@containers))} of these can be imported now
                  </p>
                  <p class="text-xs text-base-content/50 mt-1">
                    They have a folder mount under {AdoptionPolicy.adoption_root()}, so adoption
                    knows where their data lives.
                  </p>
                </div>
              </div>
              <.link
                navigate={~p"/settings?section=import"}
                class="shrink-0 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90"
              >
                Review import
              </.link>
            </div>
          </div>

          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
            <div
              :if={visible(@containers, @active_tab) == []}
              class="px-6 py-12 text-center"
            >
              <.icon name="hero-cube" class="size-8 text-base-content/15 mx-auto" />
              <p class="text-sm text-base-content/40 mt-3">{empty_message(@active_tab)}</p>
            </div>

            <div class="divide-y divide-base-content/[0.06]">
              <div :for={container <- visible(@containers, @active_tab)}>
                <button
                  type="button"
                  phx-click="toggle"
                  phx-value-id={container.id}
                  class="w-full text-left px-5 py-4 hover:bg-base-content/[0.02] cursor-pointer"
                >
                  <div class="flex items-center gap-4">
                    <span class={[
                      "shrink-0 px-2 py-0.5 rounded text-[11px] font-medium",
                      state_tone(container.state)
                    ]}>
                      {container.state || "unknown"}
                    </span>

                    <div class="min-w-0 flex-1">
                      <div class="flex items-center gap-2 flex-wrap">
                        <span class="text-sm font-medium text-base-content truncate">
                          {container.name}
                        </span>
                        <span
                          :if={container.managed}
                          class="px-2 py-0.5 rounded text-[10px] font-medium bg-primary/15 text-primary"
                        >
                          managed
                        </span>
                        <span
                          :if={not container.managed and container.in_scope}
                          class="px-2 py-0.5 rounded text-[10px] font-medium bg-info/15 text-info"
                        >
                          importable
                        </span>
                        <span
                          :if={container.compose_project}
                          class="px-2 py-0.5 rounded text-[10px] font-medium bg-base-content/[0.06] text-base-content/50"
                        >
                          {container.compose_project}
                        </span>
                      </div>
                      <p class="text-xs text-base-content/40 truncate mt-0.5 font-mono">
                        {container.image}
                      </p>
                    </div>

                    <div class="shrink-0 text-right hidden sm:block">
                      <p class="text-xs text-base-content/40">
                        {length(container.mounts)} {if length(container.mounts) == 1,
                          do: "mount",
                          else: "mounts"}
                      </p>
                      <p :if={skip_reason(container)} class="text-[11px] text-base-content/30 mt-0.5">
                        {skip_reason(container)}
                      </p>
                    </div>

                    <.icon
                      name={
                        if @expanded == container.id, do: "hero-chevron-up", else: "hero-chevron-down"
                      }
                      class="size-4 text-base-content/25 shrink-0"
                    />
                  </div>
                </button>

                <div :if={@expanded == container.id} class="px-5 pb-5 bg-base-200/30">
                  <div class="grid gap-4 sm:grid-cols-2 pt-4">
                    <.detail label="Container ID" value={short_id(container.id)} mono />
                    <.detail label="Restart policy" value={container.restart_policy || "no"} />
                    <.detail
                      :if={container.compose_service}
                      label="Compose service"
                      value={container.compose_service}
                    />
                    <.detail :if={container.user} label="Runs as" value={container.user} mono />
                    <.detail
                      :if={container.host_network}
                      label="Network"
                      value="host — shares the host's ports directly"
                    />
                    <.detail
                      :if={container.netns_parent_container_id}
                      label="Network namespace"
                      value={"inside " <> short_id(container.netns_parent_container_id)}
                      mono
                    />
                    <.detail
                      :if={container.capabilities_add != []}
                      label="Added capabilities"
                      value={Enum.join(container.capabilities_add, ", ")}
                      mono
                    />
                    <.detail
                      :if={container.devices != []}
                      label="Devices"
                      value={Enum.map_join(container.devices, ", ", &device_label/1)}
                      mono
                    />
                  </div>

                  <div class="mt-5">
                    <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/25 mb-2">
                      Mounts
                    </p>
                    <p :if={container.mounts == []} class="text-xs text-base-content/30 italic">
                      No mounts — this container keeps nothing across a recreate.
                    </p>
                    <div class="space-y-1">
                      <div
                        :for={mount <- container.mounts}
                        class="flex items-center gap-3 text-xs py-1.5 px-3 rounded bg-base-100 border border-base-content/[0.06]"
                      >
                        <span class="shrink-0 w-11 text-[10px] uppercase tracking-wide text-base-content/30">
                          {mount.type}
                        </span>
                        <span class="font-mono text-base-content/70 truncate">{mount.source}</span>
                        <.icon name="hero-arrow-right" class="size-3 text-base-content/20 shrink-0" />
                        <span class="font-mono text-base-content/70 truncate">{mount.target}</span>
                        <span
                          :if={not mount.rw}
                          class="shrink-0 px-1.5 py-0.5 rounded text-[10px] bg-base-content/[0.06] text-base-content/40"
                        >
                          read-only
                        </span>
                        <span class="ml-auto shrink-0 text-[10px] text-base-content/30">
                          {mount.tier}
                        </span>
                      </div>
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :mono, :boolean, default: false

  defp detail(assigns) do
    ~H"""
    <div>
      <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/25">
        {@label}
      </p>
      <p class={["text-xs text-base-content/70 mt-1", @mono && "font-mono"]}>{@value}</p>
    </div>
    """
  end

  defp importable(containers),
    do: Enum.filter(containers, &(not &1.managed and &1.in_scope))

  defp device_label(%{"host_path" => host, "container_path" => cont}), do: "#{host}:#{cont}"
  defp device_label(%{host_path: host, container_path: cont}), do: "#{host}:#{cont}"
  defp device_label(other), do: inspect(other)

  defp tab_label("unmanaged"), do: "Unmanaged"
  defp tab_label("managed"), do: "Managed"
  defp tab_label("all"), do: "All"

  defp empty_message("unmanaged"),
    do: "Nothing unmanaged — every container on this daemon carries the homelab.managed label."

  defp empty_message("managed"), do: "This app has not deployed any containers yet."
  defp empty_message(_), do: "The daemon reports no containers at all."
end
