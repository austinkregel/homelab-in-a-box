defmodule HomelabWeb.BackupsLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Backups
  alias Homelab.Deployments

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()
    backups = Backups.list_backup_jobs()
    deployments = Deployments.list_deployments()

    # Listing the repository shells out to the backup provider, so it must not block
    # the first render.
    if connected?(socket), do: send(self(), :load_snapshots)

    socket =
      socket
      |> assign(:page_title, "Backups")
      |> assign(:tenants, tenants)
      |> assign(:backups, backups)
      |> assign(:deployments, deployments)
      |> assign(:coverage, Backups.coverage())
      |> assign(:snapshots, :loading)
      |> assign(:show_backup_dropdown, false)

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_snapshots, socket) do
    {:noreply, assign(socket, :snapshots, Backups.repo_snapshots())}
  end

  @impl true
  def handle_event("toggle_backup_dropdown", _params, socket) do
    {:noreply, assign(socket, :show_backup_dropdown, !socket.assigns.show_backup_dropdown)}
  end

  def handle_event("trigger_backup", %{"deployment_id" => deployment_id}, socket) do
    deployment_id = String.to_integer(deployment_id)

    case Backups.create_backup_job(%{
           deployment_id: deployment_id,
           scheduled_at: DateTime.utc_now()
         }) do
      {:ok, job} ->
        # `execute_backup/1` is SYNCHRONOUS and its return was discarded, so a backup
        # that failed wrote `status: :failed` to the row while the operator was told it
        # succeeded — and `Readiness` reads these jobs, so the deployment then claimed
        # protection it did not have.
        result = Backups.execute_backup(job)

        socket =
          socket
          |> assign(:backups, Backups.list_backup_jobs())
          |> assign(:show_backup_dropdown, false)

        case result do
          {:ok, %{status: :completed}} ->
            {:noreply, put_flash(socket, :info, "Backup completed.")}

          {:ok, %{status: :failed, error_message: message}} ->
            {:noreply, put_flash(socket, :error, "Backup failed: #{message}")}

          {:ok, _job} ->
            {:noreply, put_flash(socket, :info, "Backup started.")}

          {:error, reason} ->
            {:noreply, put_flash(socket, :error, "Backup failed: #{inspect(reason)}")}
        end

      {:error, _changeset} ->
        {:noreply, put_flash(socket, :error, "Failed to create backup job")}
    end
  end

  def handle_event("restore", %{"backup_id" => backup_id}, socket) do
    case Backups.restore_backup(backup_id) do
      :ok ->
        {:noreply,
         socket
         |> put_flash(:info, "Backup restore completed successfully!")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Restore failed: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_backup", %{"backup_id" => backup_id}, socket) do
    case Backups.get_backup_job(backup_id) do
      {:ok, %{status: :running}} ->
        {:noreply, put_flash(socket, :error, "Can't delete a backup while it's running.")}

      {:ok, job} ->
        Backups.delete_backup_job(job)

        {:noreply,
         socket
         |> assign(:backups, Backups.list_backup_jobs())
         |> put_flash(:info, "Backup job deleted. The remote snapshot was not removed.")}

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Backup not found.")}
    end
  end

  defp format_size(nil), do: "—"
  defp format_size(0), do: "—"
  defp format_size(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_size(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_size(bytes), do: "#{Float.round(bytes / 1_048_576, 1)} MB"

  defp format_datetime(nil), do: "—"

  defp format_datetime(dt) do
    Calendar.strftime(dt, "%b %d, %Y %H:%M")
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
        <div class="relative overflow-hidden rounded-2xl bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-8">
          <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl"></div>
          <div class="relative flex items-start justify-between">
            <div>
              <div class="flex items-center gap-3 mb-2">
                <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                  <.icon name="hero-archive-box-solid" class="size-5 text-primary" />
                </div>
                <h1 class="text-2xl font-bold text-base-content tracking-tight">Backups</h1>
              </div>
              <p class="text-sm text-base-content/50 max-w-lg leading-relaxed mt-1">
                Which apps are protected, what the repository actually holds, and every backup run.
              </p>
            </div>
            <div class="relative">
              <button
                type="button"
                phx-click="toggle_backup_dropdown"
                class="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 hover:-translate-y-0.5 transition-all duration-200 cursor-pointer"
              >
                <.icon name="hero-plus-mini" class="size-4" />
                <span>Backup Now</span>
                <.icon name="hero-chevron-down-mini" class="size-4" />
              </button>
              <div
                :if={@show_backup_dropdown}
                class="absolute right-0 mt-2 w-64 rounded-xl border border-base-content/[0.08] bg-base-100 shadow-xl py-2 z-10"
              >
                <button
                  :for={d <- @deployments}
                  type="button"
                  phx-click="trigger_backup"
                  phx-value-deployment_id={d.id}
                  class="w-full text-left px-4 py-2.5 text-sm text-base-content hover:bg-base-content/[0.05] transition-colors cursor-pointer"
                >
                  {d.app_template.name} ({d.tenant.name})
                </button>
              </div>
            </div>
          </div>
        </div>

        <%!-- Coverage: every app and whether anything protects it --%>
        <div>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold text-base-content">Coverage</h2>
            <span class="text-xs text-base-content/40">
              {Enum.count(@coverage, &(&1.state == :protected))} of {length(@coverage)} protected
            </span>
          </div>

          <div
            :if={@coverage == []}
            class="rounded-2xl border border-base-content/[0.06] bg-base-100 px-6 py-10 text-center"
          >
            <p class="text-sm text-base-content/50">Nothing is deployed yet.</p>
          </div>

          <div
            :if={@coverage != []}
            class="rounded-2xl border border-base-content/[0.06] bg-base-100 divide-y divide-base-content/[0.04] overflow-hidden"
          >
            <div :for={row <- @coverage} class="flex items-center gap-4 px-4 py-3">
              <.link
                navigate={~p"/deployments/#{row.deployment.id}?tab=backups"}
                class="flex-1 min-w-0"
              >
                <p class="text-sm font-medium text-base-content truncate">
                  {row.deployment.app_template.name}
                </p>
                <p class="text-xs text-base-content/35 truncate">{row.deployment.tenant.name}</p>
              </.link>
              <span class="text-xs text-base-content/40 hidden sm:block">
                {last_backup_label(row)}
              </span>
              <span class={[
                "text-[11px] font-medium px-2.5 py-1 rounded-full flex-shrink-0",
                coverage_classes(row.state)
              ]}>
                {coverage_label(row.state)}
              </span>
            </div>
          </div>
        </div>

        <%!-- What is actually in the repository, including snapshots nothing points at --%>
        <div>
          <div class="flex items-baseline justify-between mb-3">
            <h2 class="text-sm font-semibold text-base-content">In the repository</h2>
            <span
              :if={is_tuple(@snapshots) and elem(@snapshots, 0) == :ok}
              class="text-xs text-base-content/40"
            >
              {Enum.count(elem(@snapshots, 1), &(&1.state == :orphaned))} with no deployment
            </span>
          </div>

          <div class="rounded-2xl border border-base-content/[0.06] bg-base-100 overflow-hidden">
            <p
              :if={@snapshots == :loading}
              class="px-6 py-10 text-center text-sm text-base-content/40"
            >
              Reading the backup repository…
            </p>

            <div :if={match?({:error, _}, @snapshots)} class="px-6 py-10 text-center">
              <p class="text-sm text-base-content/50 mb-1">Could not read the repository.</p>
              <p class="text-xs text-base-content/35 font-mono">{inspect(elem(@snapshots, 1))}</p>
            </div>

            <%= if match?({:ok, _}, @snapshots) do %>
              <p
                :if={elem(@snapshots, 1) == []}
                class="px-6 py-10 text-center text-sm text-base-content/40"
              >
                The repository holds no snapshots.
              </p>
              <div :if={elem(@snapshots, 1) != []} class="divide-y divide-base-content/[0.04]">
                <div :for={snapshot <- elem(@snapshots, 1)} class="flex items-center gap-4 px-4 py-3">
                  <span class="text-xs font-mono text-base-content/70 w-20 flex-shrink-0">
                    {snapshot.id}
                  </span>
                  <span class="text-xs text-base-content/40 flex-1 min-w-0 truncate font-mono">
                    {Enum.join(snapshot.paths, ", ")}
                  </span>
                  <span class="text-xs text-base-content/40 hidden sm:block">{snapshot.time}</span>
                  <span class={[
                    "text-[11px] font-medium px-2.5 py-1 rounded-full flex-shrink-0",
                    if(snapshot.state == :orphaned,
                      do: "bg-warning/10 text-warning",
                      else: "bg-base-200 text-base-content/50"
                    )
                  ]}>
                    {if snapshot.state == :orphaned, do: "no deployment", else: "tracked"}
                  </span>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Backups table --%>
        <div class="rounded-2xl border border-base-content/[0.06] bg-base-100 overflow-hidden">
          <div :if={@backups == []} class="px-6 py-16 text-center">
            <div class="mx-auto w-14 h-14 rounded-2xl bg-base-200/80 flex items-center justify-center mb-4">
              <.icon name="hero-archive-box" class="size-6 text-base-content/20" />
            </div>
            <p class="text-sm font-medium text-base-content/60 mb-1">No backups yet</p>
            <p class="text-xs text-base-content/35 leading-relaxed max-w-[280px] mx-auto mb-4">
              Backups are created automatically on schedule or trigger one manually above.
            </p>
          </div>

          <div :if={@backups != []}>
            <table class="w-full">
              <thead>
                <tr class="border-b border-base-content/[0.06]">
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    App
                  </th>
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    Space
                  </th>
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    Status
                  </th>
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    Size
                  </th>
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    Created
                  </th>
                  <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                    Actions
                  </th>
                </tr>
              </thead>
              <tbody class="divide-y divide-base-content/[0.04]">
                <tr :for={backup <- @backups} class="hover:bg-base-content/[0.02] transition-colors">
                  <td class="px-6 py-4">
                    <span class="text-sm font-medium text-base-content">
                      {backup.deployment.app_template.name}
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <span class="text-sm text-base-content/50">{backup.deployment.tenant.name}</span>
                  </td>
                  <td class="px-6 py-4">
                    <.status_pill status={backup.status} />
                  </td>
                  <td class="px-6 py-4">
                    <span class="text-sm text-base-content/50">{format_size(backup.size_bytes)}</span>
                  </td>
                  <td class="px-6 py-4">
                    <span class="text-sm text-base-content/50">
                      {format_datetime(backup.scheduled_at)}
                    </span>
                  </td>
                  <td class="px-6 py-4">
                    <button
                      :if={backup.status == :completed && backup.snapshot_id}
                      type="button"
                      phx-click="restore"
                      phx-value-backup_id={backup.id}
                      class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium text-primary hover:bg-primary/10 transition-colors cursor-pointer"
                    >
                      <.icon name="hero-arrow-path" class="size-3.5" /> Restore
                    </button>
                    <span
                      :if={backup.status != :completed || !backup.snapshot_id}
                      class="text-sm text-base-content/25"
                    >
                      —
                    </span>
                    <button
                      :if={backup.status != :running}
                      type="button"
                      phx-click="delete_backup"
                      phx-value-backup_id={backup.id}
                      data-confirm="Delete this backup job record? The remote snapshot is not deleted."
                      class="inline-flex items-center gap-1.5 px-3 py-1.5 rounded-lg text-xs font-medium text-error hover:bg-error/10 transition-colors cursor-pointer"
                    >
                      <.icon name="hero-trash" class="size-3.5" /> Delete
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

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

  defp pill_classes(:completed), do: "bg-success/10 text-success"
  defp pill_classes(:running), do: "bg-info/10 text-info"
  defp pill_classes(:in_progress), do: "bg-info/10 text-info"
  defp pill_classes(:failed), do: "bg-error/10 text-error"
  defp pill_classes(:pending), do: "bg-warning/10 text-warning"
  defp pill_classes(_), do: "bg-base-200 text-base-content/50"

  defp dot_color(:completed), do: "bg-success"
  defp dot_color(:running), do: "bg-info"
  defp dot_color(:in_progress), do: "bg-info"
  defp dot_color(:failed), do: "bg-error"
  defp dot_color(:pending), do: "bg-warning"
  defp dot_color(_), do: "bg-base-content/30"

  defp format_status(:completed), do: "Completed"
  defp format_status(:running), do: "In progress"
  defp format_status(:in_progress), do: "In progress"
  defp format_status(:failed), do: "Failed"
  defp format_status(:pending), do: "Pending"
  defp format_status(status), do: to_string(status)

  defp coverage_label(:protected), do: "protected"
  defp coverage_label(:unverified), do: "never succeeded"
  defp coverage_label(:unprotected), do: "unprotected"

  defp coverage_classes(:protected), do: "bg-success/10 text-success"
  defp coverage_classes(:unverified), do: "bg-warning/10 text-warning"
  defp coverage_classes(:unprotected), do: "bg-error/10 text-error"

  defp last_backup_label(%{last_completed_at: nil, jobs: []}), do: "never run"
  defp last_backup_label(%{last_completed_at: nil}), do: "no successful run"
  defp last_backup_label(%{last_completed_at: at}), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
end
