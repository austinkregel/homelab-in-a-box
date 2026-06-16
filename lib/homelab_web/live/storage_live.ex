defmodule HomelabWeb.StorageLive do
  @moduledoc """
  Storage management UI. Without ZFS / homelab-zfs-agent, shows status only.
  """
  use HomelabWeb, :live_view

  alias Homelab.Tenants

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Storage")
     |> assign(:tenants, Tenants.list_active_tenants())
     |> assign(:storage_available, Homelab.Storage.available?())
     |> assign(:storage_reason, Homelab.Storage.unavailable_reason())
     |> assign(:agent_status, safe_agent_status())}
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
      <div class="max-w-3xl mx-auto space-y-6">
        <h1 class="text-2xl font-bold text-base-content">Storage</h1>

        <%= if @storage_available do %>
          <p class="text-base-content/50 text-sm">
            ZFS host agent is connected. Pool provisioning UI will appear here next.
          </p>
        <% else %>
          <div
            id="storage-unavailable-banner"
            class="rounded-lg border border-amber-500/30 bg-amber-500/10 p-4 text-amber-100"
          >
            <p class="font-medium">ZFS not available on this host</p>
            <p class="mt-2 text-sm text-amber-200/90">{@storage_reason}</p>
            <p class="mt-3 text-sm text-base-content/50">
              The control plane, deployments, workbench, and restic LAN backups work without ZFS.
              Install <code class="text-base-content/70">zfsutils-linux</code>
              and <code class="text-base-content/70">homelab-zfs-agent</code>
              when you are ready.
            </p>
          </div>
        <% end %>

        <dl :if={@agent_status} class="card bg-base-100 border border-base-content/10 p-4 text-sm">
          <dt class="text-base-content/40">Agent status</dt>
          <dd class="font-mono text-base-content/70 mt-1">{inspect(@agent_status)}</dd>
        </dl>
      </div>
    </Layouts.app>
    """
  end

  defp safe_agent_status do
    case Homelab.Storage.agent_status() do
      {:ok, s} -> s
      {:error, e} -> %{error: inspect(e)}
    end
  end
end
