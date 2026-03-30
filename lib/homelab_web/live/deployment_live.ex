defmodule HomelabWeb.DeploymentLive do
  use HomelabWeb, :live_view

  alias Homelab.Deployments
  alias Homelab.Backups
  alias Homelab.Repo
  alias Homelab.Services.BackupScheduler

  @log_poll_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Deployment")
      |> assign(:deployment, nil)
      |> assign(:active_tab, "overview")
      |> assign(:logs, "")
      |> assign(:logs_loading, false)
      |> assign(:follow_logs, false)
      |> assign(:log_timer, nil)
      |> assign(:env_edit_mode, false)
      |> assign(:env_form, nil)
      |> assign(:resource_stats, nil)
      |> assign(:traffic_stats, nil)
      |> assign(:tenants, [])
      |> assign(:siblings, [])

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, socket) do
    deployment = Deployments.get_deployment!(String.to_integer(id))
    tenants = Homelab.Tenants.list_active_tenants()

    siblings = Deployments.list_deployments_for_tenant(deployment.tenant_id)

    socket =
      socket
      |> assign(:deployment, deployment)
      |> assign(:page_title, deployment.app_template.name)
      |> assign(:tenants, tenants)
      |> assign(:siblings, siblings)

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Homelab.PubSub, "metrics:update")

        Phoenix.PubSub.subscribe(
          Homelab.PubSub,
          Homelab.Services.DockerEventListener.topic()
        )

        socket
        |> load_resource_stats()
        |> load_traffic_stats()
      else
        socket
      end

    {:noreply, socket}
  end

  @impl true
  def handle_info({:metrics, _metrics}, socket) do
    {:noreply,
     socket
     |> load_resource_stats()
     |> load_traffic_stats()}
  end

  def handle_info({:deployment_status, deployment_id, _new_status}, socket) do
    if socket.assigns.deployment && socket.assigns.deployment.id == deployment_id do
      deployment = Deployments.get_deployment!(deployment_id)
      {:noreply, assign(socket, :deployment, deployment)}
    else
      {:noreply, socket}
    end
  end

  def handle_info(:poll_logs, socket) do
    socket =
      if socket.assigns.follow_logs && socket.assigns.deployment.external_id do
        logs =
          case Homelab.Config.orchestrator().logs(socket.assigns.deployment.external_id,
                 tail: 200
               ) do
            {:ok, log_text} -> log_text
            {:error, _} -> socket.assigns.logs
          end

        timer = Process.send_after(self(), :poll_logs, @log_poll_interval)

        socket
        |> assign(:logs, logs)
        |> assign(:log_timer, timer)
      else
        assign(socket, :log_timer, nil)
      end

    {:noreply, socket}
  end

  def handle_info(:load_logs, socket) do
    deployment = socket.assigns.deployment

    logs =
      cond do
        deployment.external_id ->
          case Homelab.Config.orchestrator().logs(deployment.external_id, tail: 200) do
            {:ok, log_text} -> log_text
            {:error, _} -> "Failed to load logs."
          end

        deployment.status == :failed && deployment.error_message ->
          "Deployment failed before container started:\n\n#{deployment.error_message}"

        deployment.status == :pending ->
          "Deployment is pending — waiting for container to start."

        deployment.status == :deploying ->
          "Container is starting up..."

        true ->
          "No container associated with this deployment."
      end

    {:noreply,
     socket
     |> assign(:logs, logs)
     |> assign(:logs_loading, false)}
  end

  @impl true
  def handle_event("navigate", %{"to" => path}, socket) do
    {:noreply, push_navigate(socket, to: path)}
  end

  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    socket =
      case tab do
        "logs" ->
          send(self(), :load_logs)
          assign(socket, :logs_loading, true)

        _ ->
          if socket.assigns.log_timer, do: Process.cancel_timer(socket.assigns.log_timer)

          socket
          |> assign(:follow_logs, false)
          |> assign(:log_timer, nil)
      end

    {:noreply,
     socket
     |> assign(:active_tab, tab)}
  end

  def handle_event("toggle_follow_logs", _params, socket) do
    new_follow = !socket.assigns.follow_logs

    socket =
      if new_follow do
        timer = Process.send_after(self(), :poll_logs, @log_poll_interval)

        socket
        |> assign(:follow_logs, true)
        |> assign(:log_timer, timer)
      else
        if socket.assigns.log_timer, do: Process.cancel_timer(socket.assigns.log_timer)

        socket
        |> assign(:follow_logs, false)
        |> assign(:log_timer, nil)
      end

    {:noreply, socket}
  end

  def handle_event("refresh_logs", _params, socket) do
    send(self(), :load_logs)
    {:noreply, assign(socket, :logs_loading, true)}
  end

  def handle_event("start_env_edit", _params, socket) do
    deployment = socket.assigns.deployment
    merged = merged_env(deployment)
    form = to_form(%{"env" => merged})

    {:noreply,
     socket
     |> assign(:env_edit_mode, true)
     |> assign(:env_form, form)}
  end

  def handle_event("cancel_env_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_edit_mode, false)
     |> assign(:env_form, nil)}
  end

  def handle_event("save_env", params, socket) do
    deployment = socket.assigns.deployment
    env_overrides = params["env"] || params || %{}
    env_overrides = Map.reject(env_overrides, fn {_k, v} -> v == "" or v == nil end)

    case Deployments.update_deployment(deployment, %{env_overrides: env_overrides}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, Repo.preload(updated, [:tenant, :app_template]))
         |> assign(:env_edit_mode, false)
         |> assign(:env_form, nil)
         |> put_flash(:info, "Environment updated.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to update environment.")}
    end
  end

  def handle_event("trigger_backup", _params, socket) do
    deployment = socket.assigns.deployment

    case Backups.create_backup_job(%{
           deployment_id: deployment.id,
           scheduled_at: DateTime.utc_now()
         }) do
      {:ok, _job} ->
        BackupScheduler.check_now()

        {:noreply,
         socket
         |> put_flash(:info, "Backup triggered.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to create backup job.")}
    end
  end

  def handle_event("stop", _params, socket) do
    case Deployments.stop_deployment(socket.assigns.deployment) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> put_flash(:info, "Deployment stopped.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to stop deployment.")}
    end
  end

  def handle_event("start", _params, socket) do
    case Deployments.start_deployment(socket.assigns.deployment) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> put_flash(:info, "Deployment started.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to start deployment.")}
    end
  end

  def handle_event("restart", _params, socket) do
    case Deployments.restart_deployment(socket.assigns.deployment) do
      {:ok, _} ->
        {:noreply, put_flash(socket, :info, "Deployment restarting.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to restart deployment.")}
    end
  end

  def handle_event("delete", _params, socket) do
    Deployments.destroy_deployment(socket.assigns.deployment)

    {:noreply,
     socket
     |> put_flash(:info, "Deployment deleted.")
     |> push_navigate(to: ~p"/")}
  end

  defp load_traffic_stats(socket) do
    deployment = socket.assigns.deployment

    stats =
      if deployment.domain && deployment.domain != "" do
        svc_key =
          deployment.domain
          |> String.downcase()
          |> String.replace(".", "-")
          |> String.replace(~r/[^a-z0-9-]/, "")

        Homelab.System.TraefikMetrics.for_service(svc_key)
      else
        nil
      end

    assign(socket, :traffic_stats, stats)
  end

  defp load_resource_stats(socket) do
    stats =
      if socket.assigns.deployment.external_id do
        case Homelab.Config.orchestrator().stats(socket.assigns.deployment.external_id) do
          {:ok, data} -> data
          {:error, _} -> nil
        end
      else
        nil
      end

    assign(socket, :resource_stats, stats)
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
      <div :if={@deployment}>
        <div class="flex items-center gap-2 text-sm text-base-content/40 mb-4">
          <.link navigate={~p"/"} class="hover:text-base-content/70 transition-colors">
            Dashboard
          </.link>
          <.icon name="hero-chevron-right-mini" class="size-3.5" />
          <.link
            navigate={~p"/tenants/#{@deployment.tenant.id}"}
            class="hover:text-base-content/70 transition-colors"
          >
            {@deployment.tenant.name}
          </.link>
          <.icon name="hero-chevron-right-mini" class="size-3.5" />
          <span class="text-base-content/60">{@deployment.app_template.name}</span>
        </div>

        <%!-- Tabs --%>
        <div class="flex gap-6 border-b border-base-content/10 mb-5">
          <button
            :for={
              tab <- ["overview", "topology", "traffic", "logs", "environment", "volumes", "backups"]
            }
            type="button"
            phx-click="switch_tab"
            phx-value-tab={tab}
            class={[
              "pb-2.5 text-sm font-medium capitalize -mb-px",
              if(@active_tab == tab,
                do: "border-b-2 border-primary text-base-content",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            {tab}
          </button>
        </div>

        <%!-- Overview tab --%>
        <div :if={@active_tab == "overview"} class="space-y-4">
          <div class="flex flex-col sm:flex-row sm:items-center sm:justify-between gap-4">
            <div class="flex items-center gap-5">
              <div class="w-14 h-14 rounded-lg bg-primary/10 flex items-center justify-center overflow-hidden">
                <img
                  :if={@deployment.app_template.logo_url}
                  src={@deployment.app_template.logo_url}
                  alt=""
                  class="w-full h-full object-contain"
                />
                <.icon
                  :if={!@deployment.app_template.logo_url}
                  name="hero-cube"
                  class="size-7 text-primary"
                />
              </div>
              <div>
                <h1 class="text-2xl font-bold text-base-content">{@deployment.app_template.name}</h1>
                <.status_pill status={@deployment.status} />
              </div>
            </div>
            <div class="flex flex-wrap gap-2">
              <button
                :if={@deployment.status in [:stopped, :failed]}
                type="button"
                phx-click="start"
                class="px-4 py-2 rounded-lg bg-success text-success-content text-sm font-medium hover:bg-success/90 transition-colors"
              >
                Start
              </button>
              <button
                :if={@deployment.status == :running}
                type="button"
                phx-click="stop"
                class="px-4 py-2 rounded-lg bg-warning text-warning-content text-sm font-medium hover:bg-warning/90 transition-colors"
              >
                Stop
              </button>
              <button
                :if={@deployment.status == :running && @deployment.external_id}
                type="button"
                phx-click="restart"
                class="px-4 py-2 rounded-lg bg-info text-info-content text-sm font-medium hover:bg-info/90 transition-colors"
              >
                Restart
              </button>
              <button
                type="button"
                phx-click="delete"
                data-confirm="Are you sure you want to delete this deployment?"
                class="px-4 py-2 rounded-lg bg-error/10 text-error text-sm font-medium hover:bg-error/20 transition-colors"
              >
                Delete
              </button>
            </div>
          </div>

          <div
            :if={@deployment.status == :failed && @deployment.error_message}
            class="rounded-lg bg-error/10 border border-error/20 px-4 py-3 flex items-start gap-3"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 text-error flex-shrink-0 mt-0.5" />
            <div>
              <p class="text-sm font-semibold text-error">Deployment failed</p>
              <p class="text-sm text-error/80 mt-0.5 font-mono">{@deployment.error_message}</p>
            </div>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="rounded-lg bg-base-100 p-4 border border-base-content/5">
              <h3 class="text-sm font-semibold text-base-content/70 mb-4">Details</h3>
              <dl class="space-y-3 text-sm">
                <div>
                  <dt class="text-base-content/50">Image</dt>
                  <dd class="font-mono text-base-content">{@deployment.app_template.image}</dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Domain</dt>
                  <dd class="text-base-content">{@deployment.domain || "—"}</dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Space</dt>
                  <dd class="text-base-content">{@deployment.tenant.name}</dd>
                </div>
                <div>
                  <dt class="text-base-content/50">Created</dt>
                  <dd class="text-base-content">{format_datetime(@deployment.inserted_at)}</dd>
                </div>
                <div>
                  <dt class="text-base-content/50">External ID</dt>
                  <dd class="font-mono text-base-content/70 text-xs">
                    {@deployment.external_id || "—"}
                  </dd>
                </div>
              </dl>
            </div>

            <div :if={@resource_stats} class="rounded-lg bg-base-100 p-4 border border-base-content/5">
              <h3 class="text-sm font-semibold text-base-content/70 mb-4">Resource usage</h3>
              <div class="space-y-4">
                <div>
                  <div class="flex justify-between text-xs mb-1">
                    <span class="text-base-content/50">CPU</span>
                    <span class="text-base-content">
                      {Float.round(@resource_stats.cpu_percent || 0, 1)}%
                    </span>
                  </div>
                  <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                    <div
                      class="h-full bg-primary rounded-full transition-all"
                      style={"width: #{min_val(@resource_stats.cpu_percent || 0, 100)}%"}
                    >
                    </div>
                  </div>
                </div>
                <div>
                  <div class="flex justify-between text-xs mb-1">
                    <span class="text-base-content/50">Memory</span>
                    <span class="text-base-content">
                      {format_bytes(@resource_stats.memory_usage || 0)} / {format_bytes(
                        @resource_stats.memory_limit || 0
                      )}
                    </span>
                  </div>
                  <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                    <div
                      class="h-full bg-info rounded-full transition-all"
                      style={"width: #{memory_percent(@resource_stats)}%"}
                    >
                    </div>
                  </div>
                </div>
              </div>
            </div>
          </div>
        </div>

        <%!-- Topology tab --%>
        <div :if={@active_tab == "topology"} class="space-y-4">
          <div class="rounded-lg bg-base-100 border border-base-content/5 p-4">
            <h3 class="text-sm font-semibold text-base-content mb-4">Infrastructure Topology</h3>
            <p class="text-xs text-base-content/40 mb-6">
              Showing {@deployment.app_template.name} in context with {length(@siblings)} deployment(s) in this space.
            </p>
            <% topo = HomelabWeb.Topology.from_deployment(@deployment, @siblings) %>
            <.topology
              nodes={topo.nodes}
              edges={topo.edges}
              highlight={topo[:highlight]}
            />
          </div>
        </div>

        <%!-- Traffic tab --%>
        <div
          :if={@active_tab == "traffic"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Traffic</h3>
          </div>
          <div class="p-4">
            <%= if @deployment.domain && @deployment.domain != "" do %>
              <%= if @traffic_stats do %>
                <div class="grid grid-cols-2 md:grid-cols-4 gap-4 mb-6">
                  <div>
                    <p class="text-xs text-base-content/40 uppercase tracking-wider mb-1">Requests</p>
                    <p class="text-2xl font-bold text-base-content">
                      {format_traffic_number(@traffic_stats.requests_total || 0)}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs text-base-content/40 uppercase tracking-wider mb-1">
                      Bandwidth In
                    </p>
                    <p class="text-2xl font-bold text-base-content">
                      {format_bytes(@traffic_stats.requests_bytes_total || 0)}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs text-base-content/40 uppercase tracking-wider mb-1">
                      Bandwidth Out
                    </p>
                    <p class="text-2xl font-bold text-base-content">
                      {format_bytes(@traffic_stats.responses_bytes_total || 0)}
                    </p>
                  </div>
                  <div>
                    <p class="text-xs text-base-content/40 uppercase tracking-wider mb-1">Errors</p>
                    <p class={[
                      "text-2xl font-bold",
                      if((@traffic_stats.error_count || 0) > 0,
                        do: "text-error",
                        else: "text-base-content"
                      )
                    ]}>
                      {format_traffic_number(@traffic_stats.error_count || 0)}
                    </p>
                  </div>
                </div>

                <div :if={
                  Map.get(@traffic_stats, :status_breakdown) &&
                    map_size(@traffic_stats.status_breakdown) > 0
                }>
                  <p class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
                    Status Code Breakdown
                  </p>
                  <div class="flex flex-wrap gap-3">
                    <div
                      :for={{code, count} <- Enum.sort(@traffic_stats.status_breakdown)}
                      class={[
                        "rounded-lg px-3 py-2 text-center min-w-[80px]",
                        status_code_bg(code)
                      ]}
                    >
                      <p class="text-xs font-medium text-base-content/60">{code}</p>
                      <p class="text-sm font-bold text-base-content">
                        {format_traffic_number(count)}
                      </p>
                    </div>
                  </div>
                </div>
              <% else %>
                <p class="text-sm text-base-content/50 py-4">
                  No traffic data available yet. Metrics will appear once Traefik processes requests for this domain.
                </p>
              <% end %>
            <% else %>
              <div class="py-8 text-center">
                <.icon name="hero-globe-alt" class="size-8 text-base-content/15 mx-auto mb-3" />
                <p class="text-sm text-base-content/50">
                  No domain configured for this deployment.
                </p>
                <p class="text-xs text-base-content/30 mt-1">
                  Traffic metrics require a domain and reverse proxy routing.
                </p>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Logs tab --%>
        <div
          :if={@active_tab == "logs"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5 bg-base-200/50">
            <div class="flex items-center gap-4">
              <label class="flex items-center gap-2 text-sm cursor-pointer">
                <input
                  type="checkbox"
                  phx-click="toggle_follow_logs"
                  checked={@follow_logs}
                  class="rounded border-base-content/20"
                />
                <span class="text-base-content/70">Follow</span>
              </label>
              <button
                type="button"
                phx-click="refresh_logs"
                disabled={@logs_loading}
                class="text-sm text-primary hover:text-primary/80 disabled:opacity-50"
              >
                Refresh
              </button>
            </div>
          </div>
          <div
            id="log-viewer"
            phx-hook=".LogViewer"
            class="h-[400px] overflow-auto bg-base-300 p-4"
          >
            <pre :if={@logs_loading} class="text-sm text-base-content/50 font-mono">
              Loading logs...
            </pre>
            <pre
              :if={!@logs_loading}
              class="text-sm text-base-content font-mono whitespace-pre-wrap break-all"
            >
              {@logs}
            </pre>
          </div>
          <script :type={Phoenix.LiveView.ColocatedHook} name=".LogViewer">
            export default {
              updated() {
                this.el.scrollTop = this.el.scrollHeight
              }
            }
          </script>
        </div>

        <%!-- Environment tab --%>
        <div
          :if={@active_tab == "environment"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Environment variables</h3>
            <%= if @env_edit_mode do %>
              <div class="flex gap-2">
                <button
                  type="button"
                  phx-click="cancel_env_edit"
                  class="px-3 py-1.5 rounded-lg text-sm text-base-content/70 hover:bg-base-200 transition-colors"
                >
                  Cancel
                </button>
                <button
                  type="button"
                  phx-click="save_env"
                  class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-sm font-medium"
                >
                  Save
                </button>
              </div>
            <% else %>
              <button
                type="button"
                phx-click="start_env_edit"
                class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary/20 transition-colors"
              >
                Edit
              </button>
            <% end %>
          </div>
          <div class="p-4">
            <%= if @env_edit_mode && @env_form do %>
              <.form for={@env_form} id="env-form" phx-submit="save_env" class="space-y-4">
                <div :for={{key, val} <- merged_env(@deployment)} class="flex flex-col gap-1">
                  <label class="text-xs font-medium text-base-content/50 font-mono">{key}</label>
                  <input
                    type={
                      if String.contains?(String.upcase(key), "PASSWORD") or
                           String.contains?(String.upcase(key), "SECRET"),
                         do: "password",
                         else: "text"
                    }
                    name={"env[#{key}]"}
                    value={val}
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                </div>
                <button
                  type="submit"
                  class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
                >
                  Save
                </button>
              </.form>
            <% else %>
              <table class="w-full text-sm">
                <thead>
                  <tr class="border-b border-base-content/10">
                    <th class="text-left py-2 font-medium text-base-content/70">Variable</th>
                    <th class="text-left py-2 font-medium text-base-content/70">Value</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{key, val} <- merged_env(@deployment)}
                    class="border-b border-base-content/5"
                  >
                    <td class="py-2 font-mono text-base-content/70">{key}</td>
                    <td class="py-2 font-mono text-base-content">
                      {mask_secret(key, val)}
                    </td>
                  </tr>
                </tbody>
              </table>
            <% end %>
          </div>
        </div>

        <%!-- Volumes tab --%>
        <div
          :if={@active_tab == "volumes"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Volumes</h3>
          </div>
          <div class="p-4">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-content/10">
                  <th class="text-left py-2 font-medium text-base-content/70">Name</th>
                  <th class="text-left py-2 font-medium text-base-content/70">Mount path</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={vol <- @deployment.app_template.volumes || []}
                  class="border-b border-base-content/5"
                >
                  <td class="py-2 font-mono text-base-content/70">
                    {vol["description"] || vol["container_path"] || "—"}
                  </td>
                  <td class="py-2 font-mono text-base-content">
                    {vol["container_path"] || vol["target"] || "—"}
                  </td>
                </tr>
              </tbody>
            </table>
            <p
              :if={(@deployment.app_template.volumes || []) == []}
              class="text-sm text-base-content/50 py-4"
            >
              No volumes configured.
            </p>
          </div>
        </div>

        <%!-- Backups tab --%>
        <div
          :if={@active_tab == "backups"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Backups</h3>
            <button
              type="button"
              phx-click="trigger_backup"
              class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
            >
              Manual backup
            </button>
          </div>
          <div class="p-4">
            <table class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-content/10">
                  <th class="text-left py-2 font-medium text-base-content/70">Status</th>
                  <th class="text-left py-2 font-medium text-base-content/70">Scheduled</th>
                  <th class="text-left py-2 font-medium text-base-content/70">Completed</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={job <- Backups.list_backup_jobs_for_deployment(@deployment.id)}
                  class="border-b border-base-content/5"
                >
                  <td class="py-2"><.status_pill status={job.status} /></td>
                  <td class="py-2 text-base-content/70">{format_datetime(job.scheduled_at)}</td>
                  <td class="py-2 text-base-content/70">{format_datetime(job.completed_at)}</td>
                </tr>
              </tbody>
            </table>
            <p
              :if={Backups.list_backup_jobs_for_deployment(@deployment.id) == []}
              class="text-sm text-base-content/50 py-4"
            >
              No backups yet.
            </p>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp merged_env(deployment) do
    template = deployment.app_template
    base = template.default_env || %{}
    overrides = deployment.env_overrides || %{}
    Map.merge(base, overrides)
  end

  defp mask_secret(key, val) when is_binary(key) do
    if String.contains?(String.upcase(key), "PASSWORD") or
         String.contains?(String.upcase(key), "SECRET") or
         String.contains?(String.upcase(key), "TOKEN") do
      "••••••••"
    else
      val
    end
  end

  defp mask_secret(_, val), do: val

  defp format_datetime(nil), do: "—"
  defp format_datetime(dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")

  defp format_bytes(bytes) when is_integer(bytes) do
    if bytes >= 1_073_741_824 do
      "#{Float.round(bytes / 1_073_741_824, 1)} GB"
    else
      "#{Float.round(bytes / 1_048_576, 1)} MB"
    end
  end

  defp format_bytes(_), do: "—"

  defp memory_percent(stats) do
    usage = stats.memory_usage || 0
    limit = stats.memory_limit || 1
    min_val(round(usage / limit * 100), 100)
  end

  defp min_val(a, b) when a < b, do: a
  defp min_val(_, b), do: b

  defp status_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1.5 text-xs font-medium px-2.5 py-1 rounded-full",
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
  defp pill_classes(:stopped), do: "bg-base-200 text-base-content/50"
  defp pill_classes(:removing), do: "bg-error/10 text-error"
  defp pill_classes(:completed), do: "bg-success/10 text-success"
  defp pill_classes(_), do: "bg-base-200 text-base-content/50"

  defp dot_color(:running), do: "bg-success"
  defp dot_color(:pending), do: "bg-warning"
  defp dot_color(:deploying), do: "bg-info"
  defp dot_color(:failed), do: "bg-error"
  defp dot_color(:completed), do: "bg-success"
  defp dot_color(_), do: "bg-base-content/30"

  defp format_traffic_number(n) when is_number(n) and n >= 1_000_000,
    do: "#{Float.round(n / 1_000_000, 1)}M"

  defp format_traffic_number(n) when is_number(n) and n >= 1_000,
    do: "#{Float.round(n / 1_000, 1)}K"

  defp format_traffic_number(n) when is_number(n), do: to_string(n)
  defp format_traffic_number(_), do: "0"

  defp status_code_bg(code) when is_binary(code) do
    cond do
      String.starts_with?(code, "2") -> "bg-success/10"
      String.starts_with?(code, "3") -> "bg-info/10"
      String.starts_with?(code, "4") -> "bg-warning/10"
      String.starts_with?(code, "5") -> "bg-error/10"
      true -> "bg-base-200"
    end
  end

  defp status_code_bg(_), do: "bg-base-200"

  defp format_status(:running), do: "Running"
  defp format_status(:pending), do: "Pending"
  defp format_status(:deploying), do: "Deploying"
  defp format_status(:failed), do: "Failed"
  defp format_status(:stopped), do: "Stopped"
  defp format_status(:removing), do: "Removing"
  defp format_status(:completed), do: "Completed"
  defp format_status(status), do: to_string(status)
end
