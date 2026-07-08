defmodule HomelabWeb.WorkbenchLive do
  @moduledoc """
  The Workbench: author a Dockerfile plus supporting files, upload extra files
  into a disk-backed workspace joined to the build context, build the image
  locally, then quick-run it with volumes/networks/env wired for fast iteration.

  Quick-run containers are labeled `homelab.workbench=true` and deliberately
  **never** `homelab.managed=true` — the reconciler's orphan sweep only ever
  touches managed containers, so a Workbench run is never reaped out from under
  the user. Promoting a build to a real, managed deployment happens on the
  Catalog page (via `Configure & deploy`), which owns the deploy modal.
  """
  use HomelabWeb, :live_view

  alias Homelab.Catalog
  alias Homelab.Catalog.ImageBuilder
  alias Homelab.Workbench
  alias Homelab.Tenants

  @run_poll_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user

    socket =
      socket
      |> assign(:page_title, "Workbench")
      |> assign(:tenants, Tenants.list_active_tenants())
      |> assign(:build_files, [%{name: "Dockerfile", content: "FROM alpine:latest\n"}])
      |> assign(:build_active, 0)
      |> assign(:build_name, "")
      |> assign(:build_tag, "latest")
      |> assign(:building, false)
      |> assign(:build_log, [])
      |> assign(:build_error, nil)
      |> assign(:built_template, nil)
      |> assign(:built_image, nil)
      |> assign(:workspace_files, Workbench.list_files(user.id))
      |> assign(:workspace_used, Workbench.total_size(user.id))
      |> assign(:workspace_quota, Workbench.quota_bytes())
      |> assign(:available_volumes, [])
      |> assign(:available_networks, [])
      |> assign(:run_volumes, [])
      |> assign(:run_envs, [])
      |> assign(:run_id, nil)
      |> assign(:run_name, nil)
      |> assign(:run_status, nil)
      |> assign(:run_logs, "")
      |> assign(:run_timer, nil)
      |> assign(:running, false)
      |> allow_upload(:context_files,
        accept: :any,
        max_entries: 20,
        max_file_size: Workbench.quota_bytes(),
        auto_upload: true,
        progress: &handle_progress/3
      )

    {:ok, socket}
  end

  # Auto-upload consumes each entry as it finishes, copying it into the user's
  # disk workspace. A quota rejection surfaces as a flash and the entry is dropped.
  defp handle_progress(:context_files, entry, socket) do
    if entry.done? do
      user_id = socket.assigns.current_user.id

      result =
        consume_uploaded_entry(socket, entry, fn %{path: path} ->
          {:ok, Workbench.add_file(user_id, entry.client_name, path)}
        end)

      socket =
        case result do
          {:ok, _file} ->
            refresh_workspace(socket)

          {:error, :quota_exceeded} ->
            put_flash(socket, :error, "#{entry.client_name} exceeds the workspace quota.")

          {:error, :invalid_name} ->
            put_flash(socket, :error, "#{entry.client_name} has an unsafe file name.")

          {:error, _reason} ->
            put_flash(socket, :error, "Could not add #{entry.client_name}.")
        end

      {:noreply, socket}
    else
      {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    # Best-effort cleanup: don't leave a quick-run container behind on disconnect.
    if socket.assigns[:run_id] do
      Homelab.Config.orchestrator().undeploy(socket.assigns.run_id)
    end

    :ok
  end

  # --- Build log + result (async from the ImageBuilder task) ---

  @impl true
  def handle_info({:build_log, event}, socket) do
    case build_log_line(event) do
      nil -> {:noreply, socket}
      line -> {:noreply, assign(socket, :build_log, socket.assigns.build_log ++ [line])}
    end
  end

  def handle_info({:build_result, {:ok, image_tag}}, socket) do
    name = socket.assigns.build_name
    slug = "built-#{slugify(name)}-#{System.unique_integer([:positive]) |> rem(10000)}"

    template_attrs = %{
      slug: slug,
      name: name,
      version: socket.assigns.build_tag,
      image: image_tag,
      description: "Built in Workbench",
      source: "built",
      source_id: image_tag,
      required_env: [],
      default_env: %{},
      ports: [],
      volumes: []
    }

    case Catalog.create_app_template(template_attrs) do
      {:ok, template} ->
        {volumes, networks} = load_docker_resources()

        {:noreply,
         socket
         |> assign(:building, false)
         |> assign(:built_template, template)
         |> assign(:built_image, image_tag)
         |> assign(:available_volumes, volumes)
         |> assign(:available_networks, networks)
         |> assign(:run_volumes, [])
         |> assign(:run_envs, [])
         |> put_flash(:info, "Image built. Run it here or configure and deploy it.")}

      {:error, changeset} ->
        {:noreply,
         socket
         |> assign(:building, false)
         |> assign(:build_error, "Failed to register image: #{inspect(changeset.errors)}")}
    end
  end

  def handle_info({:build_result, {:error, reason}}, socket) do
    {:noreply,
     socket
     |> assign(:building, false)
     |> assign(:build_error, build_error_message(reason))}
  end

  # --- Quick-run log poll ---

  def handle_info(:poll_run, socket) do
    if socket.assigns.running && socket.assigns.run_id do
      orchestrator = Homelab.Config.orchestrator()

      status =
        case orchestrator.get_service(socket.assigns.run_id) do
          {:ok, service} -> service.state
          {:error, _} -> socket.assigns.run_status
        end

      logs =
        case orchestrator.logs(socket.assigns.run_id, tail: 200) do
          {:ok, log_text} -> log_text
          {:error, _} -> socket.assigns.run_logs
        end

      timer = Process.send_after(self(), :poll_run, @run_poll_interval)

      {:noreply,
       socket
       |> assign(:run_status, status)
       |> assign(:run_logs, logs)
       |> assign(:run_timer, timer)}
    else
      {:noreply, assign(socket, :run_timer, nil)}
    end
  end

  # --- Build editor events ---

  @impl true
  def handle_event("select_build_file", %{"index" => idx}, socket) do
    {:noreply, assign(socket, :build_active, String.to_integer(idx))}
  end

  def handle_event("add_build_file", _params, socket) do
    files = socket.assigns.build_files
    new_files = files ++ [%{name: "file#{length(files)}", content: ""}]
    {:noreply, assign(socket, build_files: new_files, build_active: length(new_files) - 1)}
  end

  def handle_event("remove_build_file", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    file = Enum.at(socket.assigns.build_files, idx)

    if file && file.name == "Dockerfile" do
      {:noreply, put_flash(socket, :error, "The Dockerfile is required and can't be removed.")}
    else
      files = List.delete_at(socket.assigns.build_files, idx)
      active = min(socket.assigns.build_active, max(length(files) - 1, 0))
      {:noreply, assign(socket, build_files: files, build_active: active)}
    end
  end

  def handle_event("update_build_file", params, socket) do
    idx = socket.assigns.build_active
    name = Map.get(params, "name", "")
    content = Map.get(params, "content", "")

    files =
      List.update_at(socket.assigns.build_files, idx, fn file ->
        new_name = if file.name == "Dockerfile", do: "Dockerfile", else: name
        %{file | name: new_name, content: content}
      end)

    {:noreply, assign(socket, :build_files, files)}
  end

  def handle_event("validate_upload", _params, socket), do: {:noreply, socket}

  def handle_event("delete_workspace_file", %{"name" => name}, socket) do
    Workbench.delete_file(socket.assigns.current_user.id, name)
    {:noreply, refresh_workspace(socket)}
  end

  def handle_event("build_image", %{"name" => name, "tag" => tag}, socket) do
    files = socket.assigns.build_files
    dockerfile = Enum.find(files, &(&1.name == "Dockerfile"))

    cond do
      String.trim(name) == "" ->
        {:noreply, put_flash(socket, :error, "A name is required to build.")}

      dockerfile == nil or String.trim(dockerfile.content) == "" ->
        {:noreply, put_flash(socket, :error, "The Dockerfile can't be empty.")}

      true ->
        {merged, collisions} = merge_context_files(files, socket.assigns.workspace_files)

        socket =
          if collisions == [] do
            socket
          else
            put_flash(
              socket,
              :error,
              "Editor file(s) override uploaded file(s) with the same name: #{Enum.join(collisions, ", ")}"
            )
          end

        tag = if String.trim(tag) == "", do: "latest", else: String.trim(tag)
        image_tag = "homelab-built/#{slugify(name)}:#{tag}"
        lv = self()

        Task.start(fn ->
          result =
            ImageBuilder.build(merged, [tag: image_tag], fn ev -> send(lv, {:build_log, ev}) end)

          send(lv, {:build_result, result})
        end)

        {:noreply,
         socket
         |> assign(:building, true)
         |> assign(:build_name, name)
         |> assign(:build_tag, tag)
         |> assign(:build_log, [])
         |> assign(:build_error, nil)}
    end
  end

  # --- Run panel events ---

  def handle_event("add_run_volume", _params, socket) do
    {:noreply, assign(socket, :run_volumes, socket.assigns.run_volumes ++ [%{}])}
  end

  def handle_event("remove_run_volume", %{"index" => idx}, socket) do
    volumes = List.delete_at(socket.assigns.run_volumes, String.to_integer(idx))
    {:noreply, assign(socket, :run_volumes, volumes)}
  end

  def handle_event("add_run_env", _params, socket) do
    {:noreply, assign(socket, :run_envs, socket.assigns.run_envs ++ [%{}])}
  end

  def handle_event("remove_run_env", %{"index" => idx}, socket) do
    envs = List.delete_at(socket.assigns.run_envs, String.to_integer(idx))
    {:noreply, assign(socket, :run_envs, envs)}
  end

  def handle_event("run_image", params, socket) do
    image = socket.assigns.built_image

    if is_nil(image) do
      {:noreply, put_flash(socket, :error, "Build an image first.")}
    else
      env = parse_env_params(params["env"])
      volumes = parse_run_volume_params(params["volumes"])
      networks = parse_networks(params["networks"])

      name =
        "workbench-#{slugify(socket.assigns.build_name)}-#{System.unique_integer([:positive]) |> rem(100_000)}"

      spec = %{
        service_name: name,
        image: image,
        network: "homelab-workbench",
        env: env,
        # NEVER homelab.managed=true — the reconciler sweeps managed orphans.
        labels: %{"homelab.workbench" => "true"},
        memory_limit: 0,
        cpu_limit: 0,
        volumes: volumes,
        ports: [],
        replicas: 1,
        bridge_networks: networks
      }

      case Homelab.Config.orchestrator().deploy(spec) do
        {:ok, id} ->
          timer = Process.send_after(self(), :poll_run, @run_poll_interval)

          {:noreply,
           socket
           |> assign(:run_id, id)
           |> assign(:run_name, name)
           |> assign(:running, true)
           |> assign(:run_status, :pending)
           |> assign(:run_logs, "")
           |> assign(:run_timer, timer)
           |> put_flash(:info, "Run started.")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Run failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("stop_run", _params, socket) do
    if socket.assigns.run_id do
      Homelab.Config.orchestrator().undeploy(socket.assigns.run_id)
    end

    if socket.assigns.run_timer, do: Process.cancel_timer(socket.assigns.run_timer)

    {:noreply,
     socket
     |> assign(:running, false)
     |> assign(:run_id, nil)
     |> assign(:run_name, nil)
     |> assign(:run_status, nil)
     |> assign(:run_logs, "")
     |> assign(:run_timer, nil)
     |> put_flash(:info, "Run stopped.")}
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
      <div>
        <div class="mb-5">
          <h1 class="text-2xl font-bold text-base-content">Workbench</h1>
          <p class="mt-1 text-sm text-base-content/50">
            Author a Dockerfile, upload supporting files, build the image, then quick-run it
            with volumes and networks wired for fast iteration.
          </p>
        </div>

        <div class="grid grid-cols-1 lg:grid-cols-2 gap-4">
          <%!-- Editor --%>
          <div class="rounded-lg bg-base-100 border border-base-content/5 p-3 space-y-3">
            <div class="flex items-center gap-1.5 flex-wrap border-b border-base-content/10 pb-2">
              <button
                :for={{file, idx} <- Enum.with_index(@build_files)}
                type="button"
                phx-click="select_build_file"
                phx-value-index={idx}
                class={[
                  "text-xs font-medium rounded-md px-2.5 py-1 transition-colors inline-flex items-center gap-1.5",
                  if(@build_active == idx,
                    do: "bg-primary/10 text-primary",
                    else: "text-base-content/50 hover:text-base-content/70"
                  )
                ]}
              >
                {file.name}
                <span
                  :if={file.name != "Dockerfile"}
                  phx-click="remove_build_file"
                  phx-value-index={idx}
                  class="text-base-content/30 hover:text-error"
                >
                  <.icon name="hero-x-mark-mini" class="size-3.5" />
                </span>
              </button>
              <button
                type="button"
                phx-click="add_build_file"
                class="text-xs font-medium text-base-content/50 hover:text-primary rounded-md px-2 py-1"
              >
                + add file
              </button>
            </div>

            <% active = Enum.at(@build_files, @build_active) %>
            <form :if={active} phx-change="update_build_file" class="space-y-2">
              <input
                type="text"
                name="name"
                value={active.name}
                disabled={active.name == "Dockerfile"}
                placeholder="filename"
                class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50 disabled:opacity-60"
              />
              <textarea
                name="content"
                rows="16"
                spellcheck="false"
                phx-debounce="300"
                class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
              >{active.content}</textarea>
            </form>
          </div>

          <%!-- Right column: uploads + build controls + log --%>
          <div class="space-y-3">
            <%!-- Workspace uploads --%>
            <div class="rounded-lg bg-base-100 border border-base-content/5 p-3 space-y-3">
              <div class="flex items-center justify-between">
                <h3 class="text-sm font-semibold text-base-content/70">Workspace files</h3>
                <span class="text-xs text-base-content/40">
                  {format_bytes(@workspace_used)} / {format_bytes(@workspace_quota)}
                </span>
              </div>

              <div class="h-2 rounded-full bg-base-200 overflow-hidden">
                <div
                  class="h-full bg-primary rounded-full transition-all"
                  style={"width: #{quota_percent(@workspace_used, @workspace_quota)}%"}
                >
                </div>
              </div>

              <form phx-change="validate_upload" phx-submit="validate_upload" id="upload-form">
                <label class="flex items-center gap-2 text-xs font-medium text-primary cursor-pointer">
                  <.icon name="hero-arrow-up-tray-mini" class="size-3.5" />
                  <span>Upload files</span>
                  <.live_file_input upload={@uploads.context_files} class="sr-only" />
                </label>
                <p
                  :for={err <- upload_errors(@uploads.context_files)}
                  class="text-[11px] text-error mt-1"
                >
                  {upload_error_to_string(err)}
                </p>
              </form>

              <ul :if={@workspace_files != []} class="space-y-1">
                <li
                  :for={file <- @workspace_files}
                  class="flex items-center justify-between text-xs rounded-md bg-base-200/50 px-2.5 py-1.5"
                >
                  <span class="font-mono text-base-content/70 truncate">{file.name}</span>
                  <span class="flex items-center gap-2 flex-shrink-0">
                    <span class="text-base-content/40">{format_bytes(file.size)}</span>
                    <button
                      type="button"
                      phx-click="delete_workspace_file"
                      phx-value-name={file.name}
                      data-confirm={"Remove #{file.name} from the workspace?"}
                      class="text-base-content/30 hover:text-error"
                    >
                      <.icon name="hero-x-mark-mini" class="size-3.5" />
                    </button>
                  </span>
                </li>
              </ul>
              <p :if={@workspace_files == []} class="text-[11px] text-base-content/30">
                No uploaded files yet. Uploaded files join the build context.
              </p>
            </div>

            <%!-- Build controls --%>
            <form
              phx-submit="build_image"
              class="rounded-lg bg-base-100 border border-base-content/5 p-3 space-y-3"
            >
              <div class="flex gap-2">
                <input
                  type="text"
                  name="name"
                  value={@build_name}
                  placeholder="Image name"
                  class="flex-1 rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
                />
                <input
                  type="text"
                  name="tag"
                  value={@build_tag}
                  placeholder="latest"
                  class="w-28 rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <button
                type="submit"
                disabled={@building}
                class="w-full py-2.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors disabled:opacity-60 inline-flex items-center justify-center gap-2"
              >
                <.icon :if={@building} name="hero-arrow-path" class="size-4 animate-spin" />
                {if(@building, do: "Building...", else: "Build image")}
              </button>
            </form>

            <div
              :if={@building || @build_log != [] || @build_error}
              class="rounded-lg bg-base-300 border border-base-content/5 p-3"
            >
              <pre class="text-[11px] font-mono text-base-content/70 whitespace-pre-wrap max-h-80 overflow-y-auto leading-relaxed">{Enum.join(@build_log, "\n")}</pre>
              <p :if={@build_error} class="mt-2 text-xs text-error font-medium">
                {@build_error}
              </p>
            </div>

            <%!-- Build success panel --%>
            <div
              :if={@built_template}
              class="rounded-lg bg-success/5 border border-success/20 p-4 space-y-3"
            >
              <div class="flex items-center gap-2">
                <.icon name="hero-check-circle" class="size-5 text-success" />
                <p class="text-sm font-semibold text-base-content">
                  Built {@built_image}
                </p>
              </div>
              <p class="text-xs text-base-content/50">
                Quick-run it below to iterate, or configure ports/env and deploy it as a managed app.
              </p>
              <.link
                navigate={~p"/catalog?template=#{@built_template.id}"}
                class="inline-flex items-center gap-1.5 text-xs font-semibold text-primary hover:text-primary/80"
              >
                <.icon name="hero-rocket-launch-mini" class="size-3.5" /> Configure &amp; deploy
              </.link>
            </div>
          </div>
        </div>

        <%!-- Run panel --%>
        <div
          :if={@built_template}
          class="mt-4 rounded-lg bg-base-100 border border-base-content/5 p-4 space-y-4"
        >
          <h3 class="text-sm font-semibold text-base-content">Quick run</h3>

          <form phx-submit="run_image" id="run-form" class="space-y-4">
            <%!-- Volumes --%>
            <div class="space-y-2">
              <p class="text-xs font-semibold text-base-content/60">Volumes</p>
              <div
                :for={{_vol, idx} <- Enum.with_index(@run_volumes)}
                class="flex items-center gap-2"
              >
                <select
                  name={"volumes[#{idx}][source]"}
                  class="rounded-md bg-base-200 border-0 text-sm text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                >
                  <option value="">Select volume...</option>
                  <option :for={v <- @available_volumes} value={v.name}>{v.name}</option>
                </select>
                <span class="text-base-content/20">→</span>
                <input
                  type="text"
                  name={"volumes[#{idx}][container_path]"}
                  placeholder="/data"
                  class="flex-1 rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                />
                <button
                  type="button"
                  phx-click="remove_run_volume"
                  phx-value-index={idx}
                  class="text-base-content/30 hover:text-error"
                >
                  <.icon name="hero-x-mark-mini" class="size-4" />
                </button>
              </div>
              <button
                type="button"
                phx-click="add_run_volume"
                class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80"
              >
                <.icon name="hero-plus-mini" class="size-3.5" /> Add volume
              </button>
            </div>

            <%!-- Networks --%>
            <div class="space-y-2">
              <p class="text-xs font-semibold text-base-content/60">Networks</p>
              <p :if={@available_networks == []} class="text-[11px] text-base-content/30">
                No networks available.
              </p>
              <label
                :for={net <- @available_networks}
                class="flex items-center gap-2 text-sm text-base-content/70"
              >
                <input
                  type="checkbox"
                  name="networks[]"
                  value={net.name}
                  class="rounded border-base-content/20"
                />
                <span class="font-mono">{net.name}</span>
              </label>
            </div>

            <%!-- Env --%>
            <div class="space-y-2">
              <p class="text-xs font-semibold text-base-content/60">Environment</p>
              <div :for={{_env, idx} <- Enum.with_index(@run_envs)} class="flex items-center gap-2">
                <input
                  type="text"
                  name={"env[#{idx}][key]"}
                  placeholder="KEY"
                  class="w-40 rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                />
                <span class="text-base-content/20">=</span>
                <input
                  type="text"
                  name={"env[#{idx}][value]"}
                  placeholder="value"
                  class="flex-1 rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                />
                <button
                  type="button"
                  phx-click="remove_run_env"
                  phx-value-index={idx}
                  class="text-base-content/30 hover:text-error"
                >
                  <.icon name="hero-x-mark-mini" class="size-4" />
                </button>
              </div>
              <button
                type="button"
                phx-click="add_run_env"
                class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80"
              >
                <.icon name="hero-plus-mini" class="size-3.5" /> Add variable
              </button>
            </div>

            <div class="flex items-center gap-3 pt-1">
              <button
                :if={!@running}
                type="submit"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90"
              >
                Run here
              </button>
              <button
                :if={@running}
                type="button"
                phx-click="stop_run"
                class="px-4 py-2 rounded-lg bg-warning text-warning-content text-sm font-medium hover:bg-warning/90"
              >
                Stop run
              </button>
              <span :if={@run_status} class="text-xs text-base-content/50">
                Status: <span class="font-medium text-base-content/70">{@run_status}</span>
              </span>
            </div>
          </form>

          <div
            :if={@running || @run_logs != ""}
            id="run-log-viewer"
            phx-hook=".RunLogViewer"
            class="h-64 overflow-auto rounded-lg bg-base-300 p-3"
          >
            <pre class="text-[11px] font-mono text-base-content/70 whitespace-pre-wrap break-all">{@run_logs}</pre>
            <script :type={Phoenix.LiveView.ColocatedHook} name=".RunLogViewer">
              export default {
                updated() {
                  this.el.scrollTop = this.el.scrollHeight
                }
              }
            </script>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  # --- Helpers ---

  defp refresh_workspace(socket) do
    user_id = socket.assigns.current_user.id

    socket
    |> assign(:workspace_files, Workbench.list_files(user_id))
    |> assign(:workspace_used, Workbench.total_size(user_id))
  end

  defp load_docker_resources do
    orchestrator = Homelab.Config.orchestrator()

    volumes =
      case orchestrator.list_volumes() do
        {:ok, list} -> list
        _ -> []
      end

    networks =
      case orchestrator.list_networks() do
        {:ok, list} -> list
        _ -> []
      end

    {volumes, networks}
  end

  # Combines editor files with workspace uploads. Editor files win on a name
  # collision; the overridden upload names are returned so the UI can warn.
  defp merge_context_files(text_files, workspace_files) do
    text_names = MapSet.new(text_files, & &1.name)

    {kept, collisions} =
      Enum.reduce(workspace_files, {[], []}, fn wf, {kept, coll} ->
        if MapSet.member?(text_names, wf.name) do
          {kept, [wf.name | coll]}
        else
          {[%{name: wf.name, path: wf.path} | kept], coll}
        end
      end)

    {text_files ++ Enum.reverse(kept), Enum.reverse(collisions)}
  end

  defp parse_env_params(nil), do: %{}

  defp parse_env_params(map) when is_map(map) do
    map
    |> Map.values()
    |> Enum.reduce(%{}, fn row, acc ->
      key = String.trim(row["key"] || "")
      if key == "", do: acc, else: Map.put(acc, key, row["value"] || "")
    end)
  end

  defp parse_run_volume_params(nil), do: []

  defp parse_run_volume_params(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, vol} ->
      %{source: vol["source"], target: vol["container_path"], type: "volume"}
    end)
    |> Enum.reject(fn v ->
      v.source in [nil, ""] or v.target in [nil, ""]
    end)
  end

  defp parse_networks(nil), do: []
  defp parse_networks(list) when is_list(list), do: list
  defp parse_networks(value) when is_binary(value), do: [value]

  defp build_log_line(%{"stream" => text}) when is_binary(text) do
    case String.trim_trailing(text, "\n") do
      "" -> nil
      line -> line
    end
  end

  defp build_log_line(%{"error" => text}) when is_binary(text), do: "ERROR: #{text}"
  defp build_log_line(%{"status" => text}) when is_binary(text), do: text
  defp build_log_line(_), do: nil

  defp build_error_message({:build_failed, msg}), do: msg

  defp build_error_message({:context_failed, reason}),
    do: "Build context error: #{inspect(reason)}"

  defp build_error_message(:missing_dockerfile), do: "A Dockerfile is required."
  defp build_error_message(:unnamed_file), do: "Every file must have a name."
  defp build_error_message(reason), do: "Build failed: #{inspect(reason)}"

  defp upload_error_to_string(:too_large), do: "File exceeds the workspace quota."
  defp upload_error_to_string(:too_many_files), do: "Too many files (max 20)."
  defp upload_error_to_string(:not_accepted), do: "File type not accepted."
  defp upload_error_to_string(err), do: to_string(err)

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp quota_percent(_used, quota) when quota in [nil, 0], do: 0

  defp quota_percent(used, quota) do
    min(round(used / quota * 100), 100)
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(_), do: "0 B"
end
