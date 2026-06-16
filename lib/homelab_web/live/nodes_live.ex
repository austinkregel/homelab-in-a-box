defmodule HomelabWeb.NodesLive do
  @moduledoc """
  Swarm node registry and join preflight checklist (§D). Preflight execution is stubbed until swarm is active.
  """
  use HomelabWeb, :live_view

  alias Homelab.Cluster

  @impl true
  def mount(_params, _session, socket) do
    tenants = Homelab.Tenants.list_active_tenants()

    {:ok,
     socket
     |> assign(:page_title, "Nodes")
     |> assign(:tenants, tenants)
     |> assign(:nodes, Cluster.list_nodes())
     |> assign(:preflight, default_preflight())}
  end

  @impl true
  def handle_event("register_local", _, socket) do
    case Cluster.upsert_local_manager() do
      {:ok, node} ->
        {:noreply,
         socket
         |> assign(:nodes, Cluster.list_nodes())
         |> put_flash(:info, "Registered #{node.hostname} as manager")}

      {:error, changeset} ->
        {:noreply, put_flash(socket, :error, "Failed: #{inspect(changeset.errors)}")}
    end
  end

  @impl true
  def handle_event("toggle_preflight", %{"key" => key}, socket) do
    preflight =
      update_in(socket.assigns.preflight[key], fn
        %{checked: c} = item -> %{item | checked: !c}
      end)

    {:noreply, assign(socket, :preflight, preflight)}
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
        <div class="flex items-center justify-between">
          <div>
            <h1 class="text-2xl font-bold text-base-content">Nodes</h1>
            <p class="text-sm text-base-content/50 mt-1">
              Multi-site Docker Swarm membership and replication targets.
            </p>
          </div>
          <button
            id="nodes-register-local"
            type="button"
            phx-click="register_local"
            class="btn btn-primary btn-sm"
          >
            Register this host
          </button>
        </div>

        <div class="card bg-base-100 border border-base-content/10 overflow-hidden">
          <div :if={@nodes == []} class="px-4 py-8 text-center text-sm text-base-content/40">
            No nodes registered yet.
          </div>
          <ul :if={@nodes != []} class="divide-y divide-base-content/5">
            <li :for={n <- @nodes} id={"node-#{n.id}"} class="px-4 py-3 flex justify-between text-sm">
              <div>
                <p class="font-medium text-base-content">{n.hostname}</p>
                <p class="text-base-content/40">{n.role} · {n.site_label}</p>
              </div>
              <span class="badge badge-ghost">{n.status}</span>
            </li>
          </ul>
        </div>

        <div class="card bg-base-100 border border-base-content/10 p-4">
          <h2 class="text-sm font-semibold text-base-content mb-3">Join preflight (manual)</h2>
          <p class="text-xs text-base-content/40 mb-4">
            Confirm each item on your overlay (ZeroTier, WireGuard, or Tailscale) before joining a remote worker.
            Automated checks will run via a swarm netcheck task when swarm mode is enabled.
          </p>
          <ul class="space-y-2">
            <li :for={{key, item} <- @preflight} class="flex items-start gap-3">
              <input
                type="checkbox"
                id={"preflight-#{key}"}
                checked={item.checked}
                phx-click="toggle_preflight"
                phx-value-key={key}
                class="mt-1 rounded border-base-content/20"
              />
              <label for={"preflight-#{key}"} class="text-sm text-base-content/80">
                <span class="font-medium text-base-content">{item.label}</span>
                <span class="block text-xs text-base-content/40">{item.hint}</span>
              </label>
            </li>
          </ul>
          <p
            :if={preflight_ready?(@preflight)}
            id="preflight-ready"
            class="mt-4 text-sm text-emerald-400"
          >
            Preflight checklist complete — you may issue a swarm join token (coming soon).
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp default_preflight do
    %{
      "tcp_2377" => %{
        label: "2377/tcp reachable (swarm control)",
        hint: "Manager API from remote node over your tunnel",
        checked: false
      },
      "udp_4789" => %{
        label: "4789/udp reachable (VXLAN overlay)",
        hint: "Encrypted overlay between sites",
        checked: false
      },
      "latency" => %{
        label: "Cross-site latency acceptable",
        hint: "Note RTT; high latency affects replication",
        checked: false
      }
    }
  end

  defp preflight_ready?(preflight), do: Enum.all?(preflight, fn {_, v} -> v.checked end)
end
