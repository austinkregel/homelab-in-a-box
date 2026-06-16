defmodule HomelabWeb.AdoptionLive do
  @moduledoc """
  Legacy homelab appdata inventory and runbooks (read-only on production paths).
  """
  use HomelabWeb, :live_view

  alias Homelab.Adoption
  alias Homelab.Adoption.{AdoptedApp, Inventory, Runbook}
  alias Homelab.Repo
  alias Homelab.Tenants

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Adoption")
     |> assign(:tenants, Tenants.list_active_tenants())
     |> assign(:apps, Adoption.list_adopted_apps())
     |> assign(:source_root, Adoption.source_root())
     |> assign(:scan_error, nil)}
  end

  @impl true
  def handle_event("scan", _params, socket) do
    case Inventory.scan() do
      {:ok, _} ->
        {:noreply, assign(socket, apps: Adoption.list_adopted_apps(), scan_error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, scan_error: inspect(reason))}
    end
  end

  @impl true
  def handle_event("generate_runbook", %{"id" => id}, socket) do
    app = Repo.get!(AdoptedApp, id)

    case Runbook.generate(app) do
      {:ok, md} ->
        app
        |> AdoptedApp.changeset(%{runbook_markdown: md, import_status: "runbook_ready"})
        |> Repo.update!()

        {:noreply, assign(socket, apps: Adoption.list_adopted_apps())}
    end
  end

  @impl true
  def handle_event("mark_imported", %{"id" => id}, socket) do
    app = Repo.get!(AdoptedApp, id)

    app
    |> AdoptedApp.changeset(%{import_status: "imported", imported_at: DateTime.utc_now()})
    |> Repo.update!()

    {:noreply, assign(socket, apps: Adoption.list_adopted_apps())}
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
      <div class="max-w-5xl mx-auto space-y-6">
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Legacy app adoption</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Read-only inventory of bind-mounted appdata. Production paths are never modified.
            </p>
          </div>
          <button
            id="adoption-scan-btn"
            type="button"
            phx-click="scan"
            class="btn btn-primary btn-sm"
          >
            Scan inventory
          </button>
        </div>

        <p class="text-sm text-base-content/50">
          Source root: <code class="text-base-content/70">{@source_root}</code>.
          Bind-mount with
          <code class="text-base-content/70">HOMELAB_APPDATA_BIND=$HOME/homelab/appdata</code>
          when running via <code class="text-base-content/70">build_from_scratch.sh</code>.
        </p>

        <p :if={@scan_error} id="adoption-scan-error" class="text-sm text-error">{@scan_error}</p>

        <div class="card bg-base-100 border border-base-content/10 overflow-hidden">
          <table class="min-w-full text-sm">
            <thead class="bg-base-200/50 text-base-content/50">
              <tr>
                <th class="px-4 py-2 text-left font-medium">App</th>
                <th class="px-4 py-2 text-left font-medium">Size</th>
                <th class="px-4 py-2 text-left font-medium">Class</th>
                <th class="px-4 py-2 text-left font-medium">Status</th>
                <th class="px-4 py-2 text-right font-medium">Actions</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-base-content/5">
              <tr :for={app <- @apps} id={"adopted-app-#{app.id}"}>
                <td class="px-4 py-2 text-base-content">{app.slug}</td>
                <td class="px-4 py-2 text-base-content/60">{format_bytes(app.size_bytes)}</td>
                <td class="px-4 py-2 text-base-content/60">{app.classification}</td>
                <td class="px-4 py-2 text-base-content/60">{app.import_status}</td>
                <td class="px-4 py-2 text-right space-x-2">
                  <%= if app.classification == "manual_only" do %>
                    <button
                      type="button"
                      phx-click="generate_runbook"
                      phx-value-id={app.id}
                      class="text-primary hover:underline text-xs"
                    >
                      Runbook
                    </button>
                  <% end %>
                  <button
                    type="button"
                    phx-click="mark_imported"
                    phx-value-id={app.id}
                    class="text-base-content/50 hover:underline text-xs"
                  >
                    Mark imported
                  </button>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp format_bytes(nil), do: "—"
  defp format_bytes(b), do: "#{Float.round(b / 1_048_576, 1)} MiB"
end
