defmodule HomelabWeb.SpacesLive do
  @moduledoc """
  The index for spaces.

  Spaces were reachable only as sidebar rows, and could only be created from a
  modal on the Dashboard — so there was nowhere to see them all, and nowhere
  obvious to make one. Suspended and archived spaces appear here too; the sidebar
  lists only active ones, which otherwise left them with no route at all.
  """
  use HomelabWeb, :live_view

  alias Homelab.Deployments
  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Spaces")
     |> assign(:show_create, false)
     |> assign(:space_form, to_form(Tenants.change_tenant(%Tenant{})))
     |> load_spaces()}
  end

  @impl true
  def handle_event("open_create", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_create, true)
     |> assign(:space_form, to_form(Tenants.change_tenant(%Tenant{})))}
  end

  def handle_event("close_create", _params, socket),
    do: {:noreply, assign(socket, :show_create, false)}

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
      {:ok, tenant} ->
        {:noreply,
         socket
         |> assign(:show_create, false)
         |> load_spaces()
         |> put_flash(:info, "Space \"#{tenant.name}\" created.")}

      {:error, changeset} ->
        {:noreply, assign(socket, :space_form, to_form(changeset))}
    end
  end

  defp load_spaces(socket) do
    spaces = Tenants.list_tenants()
    by_space = Enum.group_by(Deployments.list_deployments(), & &1.tenant_id)

    socket
    |> assign(:spaces, spaces)
    |> assign(:tenants, Enum.filter(spaces, &(&1.status == :active)))
    |> assign(:by_space, by_space)
  end

  defp counts(deployments) do
    %{
      total: length(deployments),
      running: Enum.count(deployments, &(&1.status == :running)),
      failed: Enum.count(deployments, &(&1.status == :failed))
    }
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
      <div class="space-y-5">
        <div class="flex items-start justify-between gap-6">
          <div>
            <h1 class="text-2xl font-bold text-base-content tracking-tight">Spaces</h1>
            <p class="text-sm text-base-content/50 mt-1">
              How deployments are grouped. A space is organizational — every signed-in user sees all of them.
            </p>
          </div>
          <button
            type="button"
            phx-click="open_create"
            class="shrink-0 flex items-center gap-2 px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors cursor-pointer"
          >
            <.icon name="hero-plus-mini" class="size-4" /> New space
          </button>
        </div>

        <div
          :if={@spaces == []}
          class="rounded-lg border border-base-content/[0.06] bg-base-100 px-6 py-16 text-center"
        >
          <div class="mx-auto w-14 h-14 rounded-lg bg-base-200/80 flex items-center justify-center mb-4">
            <.icon name="hero-folder" class="size-6 text-base-content/20" />
          </div>
          <p class="text-sm font-medium text-base-content/60 mb-1">No spaces yet</p>
          <p class="text-xs text-base-content/35">Create one to group your deployments.</p>
        </div>

        <div :if={@spaces != []} class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-3 gap-3">
          <.link
            :for={space <- @spaces}
            navigate={~p"/spaces/#{space.id}"}
            class="rounded-lg bg-base-100 border border-base-content/[0.06] p-4 hover:border-base-content/[0.14] transition-colors"
          >
            <% c = counts(Map.get(@by_space, space.id, [])) %>
            <div class="flex items-start justify-between gap-3 mb-3">
              <div class="flex items-center gap-3 min-w-0">
                <div class="w-10 h-10 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0">
                  <.icon name="hero-folder-solid" class="size-5 text-primary" />
                </div>
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-base-content truncate">{space.name}</p>
                  <p class="text-xs text-base-content/35 font-mono truncate">{space.slug}</p>
                </div>
              </div>
              <span
                :if={space.status != :active}
                class="text-[10px] font-medium px-2 py-0.5 rounded-full bg-warning/10 text-warning flex-shrink-0"
              >
                {space.status}
              </span>
            </div>

            <div class="flex items-center gap-4 text-xs">
              <span class="text-base-content/60">
                <span class="font-semibold text-base-content">{c.total}</span>
                {if c.total == 1, do: "app", else: "apps"}
              </span>
              <span :if={c.running > 0} class="flex items-center gap-1.5 text-success">
                <span class="w-1.5 h-1.5 rounded-full bg-success"></span>{c.running} running
              </span>
              <span :if={c.failed > 0} class="flex items-center gap-1.5 text-error">
                <span class="w-1.5 h-1.5 rounded-full bg-error"></span>{c.failed} failed
              </span>
            </div>
          </.link>
        </div>
      </div>

      <div
        :if={@show_create}
        class="fixed inset-0 z-50 flex items-center justify-center bg-black/50 p-4"
        phx-click="close_create"
      >
        <div class="w-full max-w-md rounded-lg bg-base-100 p-6" phx-click-away="close_create">
          <h2 class="text-lg font-semibold text-base-content mb-4">New space</h2>
          <.form
            for={@space_form}
            phx-change="validate_space"
            phx-submit="save_space"
            class="space-y-4"
          >
            <div>
              <label class="block text-xs font-medium text-base-content/60 mb-1.5">Name</label>
              <.input field={@space_form[:name]} type="text" placeholder="Media" />
            </div>
            <div>
              <label class="block text-xs font-medium text-base-content/60 mb-1.5">Slug</label>
              <.input field={@space_form[:slug]} type="text" placeholder="media" />
            </div>
            <div class="flex justify-end gap-2 pt-2">
              <button
                type="button"
                phx-click="close_create"
                class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
              >
                Cancel
              </button>
              <button
                type="submit"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 cursor-pointer"
              >
                Create space
              </button>
            </div>
          </.form>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
