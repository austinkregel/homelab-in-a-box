defmodule HomelabWeb.StorageLive do
  @moduledoc """
  One picture of where the bytes live: physical disks, Docker's named volumes, and every
  host folder mounted into a deployment.

  The three existed separately before this — a disk gauge on the dashboard, a volume
  size list in telemetry, and folder mounts buried one deployment at a time in an edit
  form. None of them answered the question people actually have, which is *what is on
  this disk and who put it there*. Joining them is the whole point of the page; see
  `Homelab.Storage` for how the join is made.

  ## Loading

  `GET /system/df` makes the daemon walk every volume and can take tens of seconds on a
  large host, so it is deliberately NOT on the mount path. The page renders the volume
  list immediately with sizes blank and fills them in when the accounting arrives — a
  volume list without sizes is still useful, and a page that blocks on the slowest
  possible daemon call reads as broken.

  ## Deleting

  Volume deletion is guarded against our OWN records, not Docker's RefCount, and the
  reason is in `Storage.delete_volume/2`: RefCount only counts running containers, so a
  stopped app's data looks exactly like garbage. The confirm step exists to put the
  consumer list in front of the operator before they override that.
  """

  use HomelabWeb, :live_view

  alias Homelab.Storage
  alias Homelab.Tenants

  @tabs ~w(disks volumes mounts)

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Storage")
      |> assign(:tenants, Tenants.list_active_tenants())
      |> assign(:active_tab, "disks")
      |> assign(:modal, nil)
      |> assign(:form_error, nil)
      |> assign(:confirm_delete, nil)
      |> assign(:usage, :loading)
      |> assign(:volume_form, blank_volume_form())
      |> assign(:mount_form, blank_mount_form())
      |> assign(:root_form, %{"name" => "", "path" => ""})
      |> load_inventory()

    if connected?(socket), do: send(self(), :load_usage)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = if params["tab"] in @tabs, do: params["tab"], else: "disks"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_info(:load_usage, socket) do
    usage = Storage.docker_usage()

    {:noreply,
     socket
     |> assign(:usage, usage)
     |> assign(:volumes, Storage.volumes(socket.assigns.consumers, usage))}
  end

  # --- navigation ----------------------------------------------------------

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> push_patch(to: ~p"/storage?tab=#{tab}")}
  end

  def handle_event("refresh", _params, socket) do
    send(self(), :load_usage)
    {:noreply, socket |> assign(:usage, :loading) |> load_inventory()}
  end

  def handle_event("open_modal", %{"modal" => modal}, socket) do
    {:noreply, socket |> assign(:modal, modal) |> assign(:form_error, nil)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply,
     socket
     |> assign(:modal, nil)
     |> assign(:form_error, nil)
     |> assign(:confirm_delete, nil)
     |> assign(:volume_form, blank_volume_form())
     |> assign(:mount_form, blank_mount_form())
     |> assign(:root_form, %{"name" => "", "path" => ""})}
  end

  # --- create a volume -----------------------------------------------------

  def handle_event("volume_form_changed", %{"volume" => params}, socket) do
    {:noreply, assign(socket, :volume_form, Map.merge(blank_volume_form(), params))}
  end

  def handle_event("create_volume", %{"volume" => params}, socket) do
    # A "docker-managed" volume must not carry a device even if the operator typed one
    # before switching the radio back — the field stays visible while they decide, and
    # sending a stale path would silently bind the volume somewhere they deselected.
    attrs = %{
      "name" => params["name"],
      "device" => if(params["backing"] == "folder", do: params["device"], else: "")
    }

    case Storage.create_volume(attrs) do
      {:ok, name} ->
        # Re-ask for sizes: the new volume is 0 bytes, but the accounting is also where
        # its RefCount comes from, and a volume missing from it renders with no size at all.
        send(self(), :load_usage)

        {:noreply,
         socket
         |> assign(:modal, nil)
         |> assign(:volume_form, blank_volume_form())
         |> load_inventory()
         |> put_flash(:info, "Created volume #{name}.")}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("ask_delete_volume", %{"name" => name}, socket) do
    volume = Enum.find(volume_list(socket), &(&1.name == name))
    {:noreply, assign(socket, :confirm_delete, volume)}
  end

  def handle_event("delete_volume", %{"name" => name}, socket) do
    # `force` because the confirm dialog IS the acknowledgement — it lists the consumers
    # by name before this event can fire.
    case Storage.delete_volume(name, force: true) do
      :ok ->
        send(self(), :load_usage)

        {:noreply,
         socket
         |> assign(:confirm_delete, nil)
         |> load_inventory()
         |> put_flash(:info, "Deleted volume #{name}.")}

      {:error, message} ->
        {:noreply, socket |> assign(:confirm_delete, nil) |> put_flash(:error, message)}
    end
  end

  # --- attach a mount ------------------------------------------------------

  def handle_event("mount_form_changed", %{"mount" => params}, socket) do
    {:noreply, assign(socket, :mount_form, Map.merge(blank_mount_form(), params))}
  end

  def handle_event("attach_mount", %{"mount" => params}, socket) do
    row = %{
      "container_path" => params["container_path"],
      "source" => params["source"],
      "type" => params["type"],
      "read_only" => params["read_only"]
    }

    if params["deployment_id"] in [nil, ""] do
      {:noreply, assign(socket, :form_error, "pick a deployment to mount into")}
    else
      case Storage.attach_mount(params["deployment_id"], row) do
        {:ok, deployment} ->
          {:noreply,
           socket
           |> assign(:modal, nil)
           |> assign(:mount_form, blank_mount_form())
           |> load_inventory()
           |> put_flash(
             :info,
             "Mounted into #{deployment.app_template.name} — recreating the container."
           )}

        {:error, message} ->
          {:noreply, assign(socket, :form_error, message)}
      end
    end
  end

  # --- mount roots ---------------------------------------------------------

  def handle_event("add_root", %{"root" => params}, socket) do
    case Storage.put_mount_root(params["name"], params["path"]) do
      {:ok, _roots} ->
        {:noreply,
         socket
         |> assign(:modal, nil)
         |> assign(:root_form, %{"name" => "", "path" => ""})
         |> load_inventory()
         |> put_flash(:info, "Registered #{params["name"]}.")}

      {:error, message} ->
        {:noreply, assign(socket, :form_error, message)}
    end
  end

  def handle_event("delete_root", %{"name" => name}, socket) do
    Storage.delete_mount_root(name)
    {:noreply, socket |> load_inventory() |> put_flash(:info, "Forgot #{name}.")}
  end

  # --- loading -------------------------------------------------------------

  # The consumer index walks every deployment, so it is built once here and handed to
  # both the volume and bind lists rather than rebuilt per section.
  defp load_inventory(socket) do
    consumers = Storage.consumer_index()
    roots = Storage.mount_roots()
    usage = Map.get(socket.assigns, :usage, :loading)

    socket
    |> assign(:consumers, consumers)
    |> assign(:roots, roots)
    |> assign(:disks, Storage.host_disks())
    |> assign(:binds, Storage.binds(consumers, roots))
    |> assign(:volumes, Storage.volumes(consumers, usage))
    |> assign(:deployments, Storage.attachable_deployments())
  end

  defp blank_volume_form,
    do: %{"name" => "", "backing" => "docker", "device" => ""}

  defp blank_mount_form,
    do: %{
      "deployment_id" => "",
      "type" => "bind",
      "source" => "",
      "container_path" => "",
      "read_only" => "false"
    }

  defp volume_list(socket) do
    case socket.assigns.volumes do
      {:ok, volumes} -> volumes
      _ -> []
    end
  end

  # --- formatting ----------------------------------------------------------

  defp format_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "—"

  defp bar_tone(percent) when is_number(percent) do
    cond do
      percent >= 90 -> "bg-error"
      percent >= 75 -> "bg-warning"
      true -> "bg-primary"
    end
  end

  defp bar_tone(_), do: "bg-primary"

  defp tab_label("disks"), do: "Disks"
  defp tab_label("volumes"), do: "Volumes"
  defp tab_label("mounts"), do: "Folder mounts"

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
                  <.icon name="hero-circle-stack-solid" class="size-5 text-primary" />
                </div>
                <h1 class="text-2xl font-bold text-base-content tracking-tight">Storage</h1>
              </div>
              <p class="text-sm text-base-content/50 max-w-2xl">
                Physical disks, Docker's named volumes, and every host folder mounted into a
                deployment — cross-referenced, so each one shows what is using it.
              </p>
            </div>
            <button
              type="button"
              phx-click="refresh"
              class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-base-100 border border-base-content/10 text-sm font-medium hover:bg-base-content/5 cursor-pointer"
            >
              <.icon name="hero-arrow-path" class={["size-4", @usage == :loading && "animate-spin"]} />
              Refresh
            </button>
          </div>
        </div>

        <%!-- Summary row --%>
        <div class="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          <.stat
            label="Disks"
            value={to_string(length(@disks))}
            hint={"#{format_bytes(Enum.sum_by(@disks, & &1.used))} used"}
          />
          <.stat label="Volumes" value={volume_count(@volumes)} hint={usage_hint(@usage)} />
          <.stat
            label="Folder mounts"
            value={to_string(length(@binds))}
            hint={"across #{bind_consumer_count(@binds)} mounts"}
          />
          <.stat
            label="Reclaimable"
            value={reclaimable(@usage)}
            hint="volumes nothing references"
          />
        </div>

        <%!-- Tabs --%>
        <div class="flex items-center gap-1 rounded-xl bg-base-200/60 p-1 w-fit">
          <button
            :for={tab <- ~w(disks volumes mounts)}
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
          </button>
        </div>

        <%= case @active_tab do %>
          <% "disks" -> %>
            {render_disks(assigns)}
          <% "volumes" -> %>
            {render_volumes(assigns)}
          <% _ -> %>
            {render_mounts(assigns)}
        <% end %>
      </div>

      {render_modals(assigns)}
    </Layouts.app>
    """
  end

  # --- Disks ---------------------------------------------------------------

  defp render_disks(assigns) do
    ~H"""
    <div class="space-y-4">
      <div
        :if={@disks == []}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-12 text-center"
      >
        <.icon name="hero-server-stack" class="size-8 text-base-content/15 mx-auto" />
        <p class="text-sm text-base-content/40 mt-3">
          <code class="text-xs">df</code>
          reported no real filesystems. In a stripped container it may not be on PATH.
        </p>
      </div>

      <div
        :for={disk <- @disks}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 px-5 py-4"
      >
        <div class="flex items-baseline justify-between gap-4 mb-3">
          <p class="text-sm font-medium text-base-content font-mono truncate">{disk.mount}</p>
          <p class="text-xs text-base-content/40 shrink-0">
            {format_bytes(disk.used)} of {format_bytes(disk.total)}
            <span class="ml-1 text-base-content/25">({Float.round(disk.percent, 1)}%)</span>
          </p>
        </div>
        <div class="h-2 rounded-full bg-base-content/[0.06] overflow-hidden">
          <div
            class={["h-full rounded-full transition-all", bar_tone(disk.percent)]}
            style={"width: #{min(disk.percent, 100)}%"}
          >
          </div>
        </div>

        <div :if={binds_on(@binds, disk) != []} class="mt-3 pt-3 border-t border-base-content/[0.06]">
          <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/25 mb-2">
            Mounted from here
          </p>
          <div class="flex flex-wrap gap-1.5">
            <span
              :for={bind <- binds_on(@binds, disk)}
              class="px-2 py-1 rounded text-[11px] font-mono bg-base-content/[0.04] text-base-content/50"
            >
              {bind.source}
              <span class="ml-1 text-base-content/30">
                ({Enum.map_join(bind.consumers, ", ", & &1.name)})
              </span>
            </span>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Volumes -------------------------------------------------------------

  defp render_volumes(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between gap-4">
        <p class="text-xs text-base-content/40">
          <span :if={@usage == :loading}>
            Asking the daemon for volume sizes — this can take a while on a big host.
          </span>
          <span :if={@usage != :loading}>
            Sizes come from the daemon's own accounting; consumers come from this app's records.
          </span>
        </p>
        <button
          type="button"
          phx-click="open_modal"
          phx-value-modal="volume"
          class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 cursor-pointer"
        >
          <.icon name="hero-plus" class="size-4" /> New volume
        </button>
      </div>

      <div
        :if={match?({:error, _}, @volumes)}
        class="rounded-lg border border-error/20 bg-error/5 px-5 py-4 text-sm text-error"
      >
        Could not list volumes: {inspect(elem(@volumes, 1))}
      </div>

      <div
        :if={@volumes == {:ok, []}}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-12 text-center"
      >
        <.icon name="hero-circle-stack" class="size-8 text-base-content/15 mx-auto" />
        <p class="text-sm text-base-content/40 mt-3">No named volumes on this daemon yet.</p>
      </div>

      <div
        :if={match?({:ok, [_ | _]}, @volumes)}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden divide-y divide-base-content/[0.06]"
      >
        <div
          :for={volume <- elem(@volumes, 1)}
          class="px-5 py-4 hover:bg-base-content/[0.02] flex items-start gap-4"
        >
          <div class="min-w-0 flex-1">
            <div class="flex items-center gap-2 flex-wrap">
              <span class="text-sm font-medium text-base-content font-mono truncate">
                {volume.name}
              </span>
              <span
                :if={volume.managed}
                class="px-2 py-0.5 rounded text-[10px] font-medium bg-primary/15 text-primary"
              >
                managed
              </span>
              <span
                :if={volume.adopted}
                class="px-2 py-0.5 rounded text-[10px] font-medium bg-info/15 text-info"
              >
                adopted
              </span>
              <span
                :if={volume.consumers == [] and volume.in_use == false}
                class="px-2 py-0.5 rounded text-[10px] font-medium bg-warning/15 text-warning"
              >
                unreferenced
              </span>
            </div>

            <p :if={volume.consumers == []} class="text-xs text-base-content/30 mt-1 italic">
              No deployment mounts this.
            </p>
            <div :if={volume.consumers != []} class="mt-1.5 flex flex-wrap gap-1.5">
              <.link
                :for={consumer <- volume.consumers}
                navigate={~p"/deployments/#{consumer.deployment_id}"}
                class="px-2 py-0.5 rounded text-[11px] bg-base-content/[0.04] text-base-content/60 hover:bg-base-content/[0.08]"
              >
                {consumer.name}
                <span class="text-base-content/30 font-mono">{consumer.container_path}</span>
                <span :if={consumer.read_only} class="text-base-content/30">· ro</span>
              </.link>
            </div>
          </div>

          <div class="shrink-0 text-right">
            <p class="text-sm text-base-content/70">{format_bytes(volume.size)}</p>
            <p class="text-[11px] text-base-content/30">{volume.driver}</p>
          </div>

          <button
            type="button"
            phx-click="ask_delete_volume"
            phx-value-name={volume.name}
            class="shrink-0 p-2 rounded-lg text-base-content/25 hover:text-error hover:bg-error/10 cursor-pointer"
            title="Delete volume"
          >
            <.icon name="hero-trash" class="size-4" />
          </button>
        </div>
      </div>
    </div>
    """
  end

  # --- Folder mounts -------------------------------------------------------

  defp render_mounts(assigns) do
    ~H"""
    <div class="space-y-6">
      <%!-- Registered roots --%>
      <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
        <div class="px-5 py-3 flex items-center justify-between border-b border-base-content/[0.06]">
          <div>
            <p class="text-sm font-medium text-base-content">Mount roots</p>
            <p class="text-xs text-base-content/40 mt-0.5">
              Host paths worth naming. The two built-ins are owned by Settings → Infrastructure.
            </p>
          </div>
          <button
            type="button"
            phx-click="open_modal"
            phx-value-modal="root"
            class="shrink-0 flex items-center gap-1.5 px-3 py-1.5 rounded-lg bg-base-200 text-sm font-medium hover:bg-base-300 cursor-pointer"
          >
            <.icon name="hero-plus" class="size-4" /> Register
          </button>
        </div>
        <div class="divide-y divide-base-content/[0.06]">
          <div
            :for={root <- @roots}
            class="px-5 py-3 flex items-center gap-4 hover:bg-base-content/[0.02]"
          >
            <span class="text-sm text-base-content/70 w-40 shrink-0 truncate">{root.name}</span>
            <span class="text-xs font-mono text-base-content/50 truncate flex-1">{root.path}</span>
            <span
              :if={root.builtin}
              class="shrink-0 px-2 py-0.5 rounded text-[10px] bg-base-content/[0.06] text-base-content/40"
            >
              built-in
            </span>
            <button
              :if={not root.builtin}
              type="button"
              phx-click="delete_root"
              phx-value-name={root.name}
              class="shrink-0 p-1.5 rounded text-base-content/25 hover:text-error hover:bg-error/10 cursor-pointer"
              title="Forget this root"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>
      </div>

      <%!-- Binds --%>
      <div class="flex items-center justify-between gap-4">
        <p class="text-xs text-base-content/40">
          Every host folder a deployment mounts, and the disk it actually lands on.
        </p>
        <button
          type="button"
          phx-click="open_modal"
          phx-value-modal="mount"
          class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 cursor-pointer"
        >
          <.icon name="hero-plus" class="size-4" /> Add mount
        </button>
      </div>

      <div
        :if={@binds == []}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-12 text-center"
      >
        <.icon name="hero-folder" class="size-8 text-base-content/15 mx-auto" />
        <p class="text-sm text-base-content/40 mt-3">
          No deployment mounts a host folder. Everything lives in named volumes.
        </p>
      </div>

      <div
        :if={@binds != []}
        class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden divide-y divide-base-content/[0.06]"
      >
        <div :for={bind <- @binds} class="px-5 py-4 hover:bg-base-content/[0.02]">
          <div class="flex items-start gap-4">
            <div class="min-w-0 flex-1">
              <p class="text-sm font-mono text-base-content truncate">{bind.source}</p>
              <div class="flex items-center gap-2 mt-1 flex-wrap">
                <span :if={bind.root} class="text-[11px] text-base-content/40">
                  under {bind.root.name}
                </span>
                <span :if={bind.disk} class="text-[11px] text-base-content/40">
                  on {bind.disk.mount} ({Float.round(bind.disk.percent, 0)}% full)
                </span>
                <span :if={is_nil(bind.disk)} class="text-[11px] text-warning">
                  not on any filesystem this process can see
                </span>
              </div>
            </div>

            <div class="shrink-0 flex flex-wrap gap-1.5 justify-end max-w-md">
              <.link
                :for={consumer <- bind.consumers}
                navigate={~p"/deployments/#{consumer.deployment_id}"}
                class="px-2 py-0.5 rounded text-[11px] bg-base-content/[0.04] text-base-content/60 hover:bg-base-content/[0.08]"
              >
                {consumer.name}
                <span class="text-base-content/30 font-mono">{consumer.container_path}</span>
                <span :if={consumer.read_only} class="text-base-content/30">· ro</span>
              </.link>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  # --- Modals --------------------------------------------------------------

  defp render_modals(assigns) do
    ~H"""
    <%!-- The backdrop deliberately has NO phx-click of its own: a click inside the panel
    bubbles up to it, so a backdrop handler would close the dialog on every keystroke's
    surrounding click. `phx-click-away` on the panel covers the backdrop click correctly. --%>
    <div
      :if={@modal || @confirm_delete}
      class="fixed inset-0 z-50 flex items-center justify-center p-4 bg-black/40"
    >
      <div
        class="w-full max-w-lg rounded-lg bg-base-100 border border-base-content/10 shadow-xl overflow-hidden"
        phx-click-away="close_modal"
      >
        <%= cond do %>
          <% @confirm_delete -> %>
            {render_confirm_delete(assigns)}
          <% @modal == "volume" -> %>
            {render_volume_modal(assigns)}
          <% @modal == "mount" -> %>
            {render_mount_modal(assigns)}
          <% @modal == "root" -> %>
            {render_root_modal(assigns)}
          <% true -> %>
        <% end %>
      </div>
    </div>
    """
  end

  defp render_volume_modal(assigns) do
    ~H"""
    <form phx-submit="create_volume" phx-change="volume_form_changed">
      <div class="px-6 py-5 border-b border-base-content/[0.06]">
        <h2 class="text-base font-semibold text-base-content">New volume</h2>
        <p class="text-xs text-base-content/40 mt-1">
          Created with <code>homelab.managed=true</code>, so the orphan sweep and the
          adoption scan both recognise it as ours.
        </p>
      </div>

      <div class="px-6 py-5 space-y-5">
        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Name</label>
          <input
            type="text"
            name="volume[name]"
            value={@volume_form["name"]}
            placeholder="media-cache"
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm font-mono focus:outline-none focus:border-primary/40"
          />
        </div>

        <div class="space-y-2">
          <label class="block text-xs font-medium text-base-content/60">Where the bytes go</label>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-content/10 cursor-pointer hover:bg-base-content/[0.02]">
            <input
              type="radio"
              name="volume[backing]"
              value="docker"
              checked={@volume_form["backing"] != "folder"}
              class="mt-0.5"
            />
            <span>
              <span class="block text-sm text-base-content">Docker-managed</span>
              <span class="block text-xs text-base-content/40 mt-0.5">
                Docker picks the location under its data root. Only Docker can find it again.
              </span>
            </span>
          </label>
          <label class="flex items-start gap-3 p-3 rounded-lg border border-base-content/10 cursor-pointer hover:bg-base-content/[0.02]">
            <input
              type="radio"
              name="volume[backing]"
              value="folder"
              checked={@volume_form["backing"] == "folder"}
              class="mt-0.5"
            />
            <span>
              <span class="block text-sm text-base-content">Backed by a host folder</span>
              <span class="block text-xs text-base-content/40 mt-0.5">
                A named volume whose bytes live in a folder you chose — so they can be backed
                up, moved, or read with <code>ls</code>. The folder must already exist.
              </span>
            </span>
          </label>
        </div>

        <div :if={@volume_form["backing"] == "folder"}>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Host folder</label>
          <input
            type="text"
            name="volume[device]"
            value={@volume_form["device"]}
            placeholder="/mnt/tank/media-cache"
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm font-mono focus:outline-none focus:border-primary/40"
          />
          <p class="text-[11px] text-base-content/30 mt-1.5">
            Registered roots: {Enum.map_join(@roots, " · ", & &1.path)}
          </p>
        </div>

        <p :if={@form_error} class="text-xs text-error">{@form_error}</p>
      </div>

      <.modal_actions submit="Create volume" />
    </form>
    """
  end

  defp render_mount_modal(assigns) do
    ~H"""
    <form phx-submit="attach_mount" phx-change="mount_form_changed">
      <div class="px-6 py-5 border-b border-base-content/[0.06]">
        <h2 class="text-base font-semibold text-base-content">Add a mount</h2>
        <p class="text-xs text-base-content/40 mt-1">
          The deployment is recreated so the container picks it up. Its existing volumes are
          kept.
        </p>
      </div>

      <div class="px-6 py-5 space-y-4">
        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Deployment</label>
          <select
            name="mount[deployment_id]"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm focus:outline-none focus:border-primary/40"
          >
            <option value="">Choose a deployment…</option>
            <option
              :for={deployment <- @deployments}
              value={deployment.id}
              selected={@mount_form["deployment_id"] == deployment.id}
            >
              {deployment.app_template.name} ({deployment.tenant && deployment.tenant.slug})
            </option>
          </select>
        </div>

        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Kind</label>
          <select
            name="mount[type]"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm focus:outline-none focus:border-primary/40"
          >
            <option value="bind" selected={@mount_form["type"] == "bind"}>
              Host folder (bind)
            </option>
            <option value="volume" selected={@mount_form["type"] == "volume"}>
              Named volume
            </option>
          </select>
        </div>

        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">
            {if @mount_form["type"] == "volume", do: "Volume name", else: "Host path"}
          </label>
          <input
            type="text"
            name="mount[source]"
            value={@mount_form["source"]}
            placeholder={
              if @mount_form["type"] == "volume", do: "media-cache", else: "/mnt/tank/media"
            }
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm font-mono focus:outline-none focus:border-primary/40"
          />
          <p :if={@mount_form["type"] == "volume"} class="text-[11px] text-base-content/30 mt-1.5">
            Leave blank to let the spec builder derive a tenant-scoped name.
          </p>
        </div>

        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">
            Path inside the container
          </label>
          <input
            type="text"
            name="mount[container_path]"
            value={@mount_form["container_path"]}
            placeholder="/media"
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm font-mono focus:outline-none focus:border-primary/40"
          />
        </div>

        <label class="flex items-center gap-2 cursor-pointer">
          <input type="hidden" name="mount[read_only]" value="false" />
          <input
            type="checkbox"
            name="mount[read_only]"
            value="true"
            checked={@mount_form["read_only"] == "true"}
            class="rounded"
          />
          <span class="text-sm text-base-content/70">Read-only</span>
        </label>

        <p :if={@form_error} class="text-xs text-error">{@form_error}</p>
      </div>

      <.modal_actions submit="Add mount and recreate" />
    </form>
    """
  end

  defp render_root_modal(assigns) do
    ~H"""
    <form phx-submit="add_root">
      <div class="px-6 py-5 border-b border-base-content/[0.06]">
        <h2 class="text-base font-semibold text-base-content">Register a mount root</h2>
        <p class="text-xs text-base-content/40 mt-1">
          A name for a host path you mount from often. Metadata only — nothing on disk is
          created or moved.
        </p>
      </div>

      <div class="px-6 py-5 space-y-4">
        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Name</label>
          <input
            type="text"
            name="root[name]"
            placeholder="tank"
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm focus:outline-none focus:border-primary/40"
          />
        </div>
        <div>
          <label class="block text-xs font-medium text-base-content/60 mb-1.5">Host path</label>
          <input
            type="text"
            name="root[path]"
            placeholder="/mnt/tank"
            autocomplete="off"
            class="w-full px-3 py-2 rounded-lg bg-base-200/60 border border-base-content/10 text-sm font-mono focus:outline-none focus:border-primary/40"
          />
        </div>
        <p :if={@form_error} class="text-xs text-error">{@form_error}</p>
      </div>

      <.modal_actions submit="Register" />
    </form>
    """
  end

  defp render_confirm_delete(assigns) do
    ~H"""
    <div>
      <div class="px-6 py-5 border-b border-base-content/[0.06]">
        <h2 class="text-base font-semibold text-base-content">
          Delete {@confirm_delete.name}?
        </h2>
      </div>

      <div class="px-6 py-5 space-y-4">
        <p class="text-sm text-base-content/60">
          Docker refuses to delete a volume a <em>running</em>
          container holds, and nothing else stands between this and the data.
        </p>

        <div
          :if={@confirm_delete.consumers != []}
          class="rounded-lg border border-error/20 bg-error/5 px-4 py-3"
        >
          <p class="text-xs font-medium text-error">
            {length(@confirm_delete.consumers)} {if length(@confirm_delete.consumers) == 1,
              do: "deployment still mounts it",
              else: "deployments still mount it"}
          </p>
          <ul class="mt-2 space-y-1">
            <li
              :for={consumer <- @confirm_delete.consumers}
              class="text-xs text-base-content/60"
            >
              {consumer.name}
              <span class="font-mono text-base-content/40">{consumer.container_path}</span>
              <span class="text-base-content/30">· {consumer.status}</span>
            </li>
          </ul>
          <p class="text-[11px] text-base-content/40 mt-2">
            A stopped deployment still owns its data. Deleting this destroys it.
          </p>
        </div>

        <p
          :if={@confirm_delete.consumers == []}
          class="text-xs text-base-content/40"
        >
          No deployment in this app's records mounts it. It may still belong to a container
          this app does not manage — check
          <.link navigate={~p"/containers"} class="text-primary hover:underline">Containers</.link>
          first.
        </p>
      </div>

      <div class="px-6 py-4 bg-base-200/40 flex items-center justify-end gap-2">
        <button
          type="button"
          phx-click="close_modal"
          class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
        >
          Cancel
        </button>
        <button
          type="button"
          phx-click="delete_volume"
          phx-value-name={@confirm_delete.name}
          class="px-4 py-2 rounded-lg bg-error text-error-content text-sm font-medium hover:bg-error/90 cursor-pointer"
        >
          Delete volume
        </button>
      </div>
    </div>
    """
  end

  attr :submit, :string, required: true

  defp modal_actions(assigns) do
    ~H"""
    <div class="px-6 py-4 bg-base-200/40 flex items-center justify-end gap-2">
      <button
        type="button"
        phx-click="close_modal"
        class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
      >
        Cancel
      </button>
      <button
        type="submit"
        class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 cursor-pointer"
      >
        {@submit}
      </button>
    </div>
    """
  end

  # --- summary helpers -----------------------------------------------------

  defp volume_count({:ok, volumes}), do: to_string(length(volumes))
  defp volume_count(_), do: "—"

  defp usage_hint(:loading), do: "sizing…"
  defp usage_hint({:ok, %{volumes: %{size: size}}}), do: "#{format_bytes(size)} total"
  defp usage_hint(_), do: "sizes unavailable"

  defp reclaimable({:ok, %{volumes: %{reclaimable: bytes}}}), do: format_bytes(bytes)
  defp reclaimable(_), do: "—"

  defp bind_consumer_count(binds),
    do: binds |> Enum.sum_by(&length(&1.consumers)) |> to_string()

  defp binds_on(binds, disk),
    do: Enum.filter(binds, &(&1.disk && &1.disk.mount == disk.mount))

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :hint, :string, default: nil

  defp stat(assigns) do
    ~H"""
    <div class="rounded-lg border border-base-content/[0.06] bg-base-100 px-5 py-4">
      <p class="text-[10px] font-semibold uppercase tracking-widest text-base-content/25">
        {@label}
      </p>
      <p class="text-2xl font-bold text-base-content mt-1">{@value}</p>
      <p :if={@hint} class="text-xs text-base-content/40 mt-0.5">{@hint}</p>
    </div>
    """
  end
end
