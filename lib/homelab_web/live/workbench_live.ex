defmodule HomelabWeb.WorkbenchLive do
  @moduledoc """
  Workbench project list and editor shell. Image build/publish requires ZFS later.
  """
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Workbench
  alias Homelab.Workbench.Project

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()

    {:ok,
     socket
     |> assign(:page_title, "Workbench")
     |> assign(:tenants, tenants)
     |> assign(:projects, Workbench.list_projects())
     |> assign(:show_new, false)
     |> assign(:publish_available, Workbench.publish_available?())
     |> assign(:storage_reason, Homelab.Storage.unavailable_reason())
     |> assign(:form, to_form(Workbench.change_project()))}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    project = Workbench.get_project!(id)

    {:noreply,
     socket
     |> assign(:page_title, "Workbench · #{project.name}")
     |> assign(:project, project)
     |> assign(:next_version, Workbench.next_version_number(project.id))}
  end

  def handle_params(_params, _uri, socket) do
    {:noreply, assign(socket, :project, nil)}
  end

  @impl true
  def handle_event("toggle_new", _, socket) do
    {:noreply, assign(socket, :show_new, !socket.assigns.show_new)}
  end

  def handle_event("validate_project", %{"project" => params}, socket) do
    form =
      %Project{}
      |> Workbench.change_project(params)
      |> Map.put(:action, :validate)
      |> to_form()

    {:noreply, assign(socket, :form, form)}
  end

  def handle_event("create_project", %{"project" => params}, socket) do
    case Workbench.create_project(params) do
      {:ok, project} ->
        {:noreply,
         socket
         |> assign(:projects, Workbench.list_projects())
         |> assign(:show_new, false)
         |> put_flash(:info, "Project #{project.name} created")
         |> push_navigate(to: ~p"/workbench/#{project.id}")}

      {:error, changeset} ->
        {:noreply, assign(socket, :form, to_form(changeset))}
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
      <.storage_unavailable :if={!@publish_available} reason={@storage_reason} />

      <%= if @project do %>
        <.project_show
          project={@project}
          next_version={@next_version}
          publish_available={@publish_available}
        />
      <% else %>
        <.project_index
          projects={@projects}
          show_new={@show_new}
          form={@form}
          tenants={@tenants}
          publish_available={@publish_available}
        />
      <% end %>
    </Layouts.app>
    """
  end

  attr :projects, :list, required: true
  attr :show_new, :boolean, required: true
  attr :form, :any, required: true
  attr :tenants, :list, required: true
  attr :publish_available, :boolean, required: true

  defp project_index(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <div class="flex items-center justify-between">
        <div>
          <h1 class="text-2xl font-bold text-base-content">Workbench</h1>
          <p class="text-sm text-base-content/50 mt-1">
            Author custom containers, version builds, and deploy without an external registry.
          </p>
        </div>
        <button
          id="workbench-new-btn"
          type="button"
          phx-click="toggle_new"
          class="rounded-lg bg-primary px-4 py-2 text-sm font-medium text-primary-content hover:opacity-90"
        >
          New project
        </button>
      </div>

      <div
        :if={@show_new}
        id="workbench-new-form"
        class="card bg-base-100 border border-base-content/10 p-4"
      >
        <.form
          for={@form}
          id="workbench-project-form"
          phx-change="validate_project"
          phx-submit="create_project"
        >
          <div class="grid gap-4 sm:grid-cols-2">
            <.input
              field={@form[:tenant_id]}
              type="select"
              label="Space"
              options={tenant_options(@tenants)}
            />
            <.input field={@form[:slug]} type="text" label="Slug" placeholder="my-service" />
            <.input field={@form[:name]} type="text" label="Name" class="sm:col-span-2" />
          </div>
          <div class="mt-4 flex justify-end gap-2">
            <button type="button" phx-click="toggle_new" class="btn btn-ghost btn-sm">Cancel</button>
            <button type="submit" class="btn btn-primary btn-sm">Create</button>
          </div>
        </.form>
      </div>

      <div class="card bg-base-100 border border-base-content/10 overflow-hidden">
        <div :if={@projects == []} class="px-4 py-10 text-center text-base-content/40 text-sm">
          No workbench projects yet.
        </div>
        <ul :if={@projects != []} class="divide-y divide-base-content/5">
          <li :for={p <- @projects} id={"workbench-project-#{p.id}"}>
            <.link
              navigate={~p"/workbench/#{p.id}"}
              class="flex items-center justify-between px-4 py-3 hover:bg-base-content/5"
            >
              <div>
                <p class="font-medium text-base-content">{p.name}</p>
                <p class="text-xs text-base-content/40">{p.slug} · {p.tenant.name}</p>
              </div>
              <.icon name="hero-chevron-right" class="size-4 text-base-content/30" />
            </.link>
          </li>
        </ul>
      </div>

      <p :if={!@publish_available} class="text-xs text-base-content/40">
        Publish and ZFS-backed build datasets unlock when the host storage agent is running.
      </p>
    </div>
    """
  end

  attr :project, :map, required: true
  attr :next_version, :integer, required: true
  attr :publish_available, :boolean, required: true

  defp project_show(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto space-y-6">
      <.link navigate={~p"/workbench"} class="text-sm text-primary hover:underline">
        ← All projects
      </.link>

      <div>
        <h1 class="text-2xl font-bold text-base-content">{@project.name}</h1>
        <p class="text-sm text-base-content/50">{@project.slug} · {@project.tenant.name}</p>
      </div>

      <div class="card bg-base-100 border border-base-content/10 p-4 space-y-3">
        <h2 class="text-sm font-semibold text-base-content">Build context</h2>
        <p class="text-sm text-base-content/50">
          File editor and Dockerfile workspace will mount here. Datasets:
          <span class="font-mono text-base-content/70">{@project.build_dataset || "—"}</span>
          (build), <span class="font-mono text-base-content/70">{@project.data_dataset || "—"}</span>
          (data).
        </p>
        <button
          id="workbench-publish-btn"
          type="button"
          disabled={!@publish_available}
          class="btn btn-primary btn-sm disabled:opacity-40"
        >
          Publish v{@next_version}
        </button>
        <p :if={!@publish_available} class="text-xs text-amber-200/80">
          Publishing requires ZFS and the local registry pipeline.
        </p>
      </div>

      <div class="card bg-base-100 border border-base-content/10 p-4">
        <h2 class="text-sm font-semibold text-base-content mb-2">Versions</h2>
        <p :if={@project.versions == []} class="text-sm text-base-content/40">
          No published versions yet.
        </p>
        <ul :if={@project.versions != []} class="space-y-2">
          <li :for={v <- @project.versions} class="text-sm font-mono text-base-content/70">
            v{v.version_number} · {String.slice(v.image_digest || "", 0, 19)}…
          </li>
        </ul>
      </div>
    </div>
    """
  end

  defp tenant_options(tenants) do
    [{"Select a space", ""}] ++ Enum.map(tenants, fn t -> {t.name, t.id} end)
  end
end
