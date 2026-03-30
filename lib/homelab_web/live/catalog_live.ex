defmodule HomelabWeb.CatalogLive do
  use HomelabWeb, :live_view

  alias Homelab.Catalog
  alias Homelab.Catalog.CatalogEntry

  alias Homelab.Tenants

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()
    registries = Homelab.Config.registries()
    catalogs = Homelab.Config.application_catalogs()

    socket =
      socket
      |> assign(:page_title, "App Catalog")
      |> assign(:tab, "curated")
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:selected_registry, nil)
      |> assign(:registries, registries)
      |> assign(:catalogs, catalogs)
      |> assign(:selected_template, nil)
      |> assign(:selected_entry, nil)
      |> assign(:enriching, false)
      |> assign(:deploy_form, nil)
      |> assign(:custom_form, to_form(%{"image" => "", "tag" => "latest", "name" => ""}))
      |> assign(:search_loading, false)
      |> assign(:curated_entries, [])
      |> assign(:show_all_registries, false)
      |> assign(:tenants, tenants)

    socket =
      if connected?(socket) do
        send(self(), :load_curated)
        socket
      else
        socket
      end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_curated, socket) do
    task =
      Task.async(fn ->
        Homelab.Config.application_catalogs()
        |> Task.async_stream(
          fn mod ->
            case mod.browse([]) do
              {:ok, list} -> list
              {:error, _} -> []
            end
          end,
          max_concurrency: 4,
          timeout: :infinity
        )
        |> Enum.flat_map(fn {:ok, list} -> list end)
      end)

    send(self(), {:curated_loaded, Task.await(task)})
    {:noreply, socket}
  end

  def handle_info({:curated_loaded, entries}, socket) do
    {:noreply, assign(socket, :curated_entries, deduplicate_entries(entries))}
  end

  def handle_info({:enrichment_complete, enriched_entry}, socket) do
    if socket.assigns.selected_entry do
      template = update_template_from_enrichment(socket.assigns.selected_template, enriched_entry)
      deploy_form = build_deploy_form(template)

      {:noreply,
       socket
       |> assign(:selected_entry, enriched_entry)
       |> assign(:selected_template, template)
       |> assign(:deploy_form, deploy_form)
       |> assign(:deploy_ports, template.ports || [])
       |> assign(:deploy_volumes, template.volumes || [])
       |> assign(:enriching, false)}
    else
      {:noreply, assign(socket, :enriching, false)}
    end
  end

  def handle_info({:do_search, query, selected_registry}, socket) do
    searchable =
      if selected_registry do
        case Enum.find(socket.assigns.registries, &(&1.driver_id() == selected_registry)) do
          nil -> []
          mod -> [mod]
        end
      else
        socket.assigns.registries
      end

    results =
      searchable
      |> Task.async_stream(
        fn mod ->
          case mod.search(query, []) do
            {:ok, entries} -> entries
            {:error, _} -> []
          end
        end,
        max_concurrency: 4,
        timeout: :infinity
      )
      |> Enum.flat_map(fn {:ok, list} -> list end)

    {:noreply,
     socket
     |> assign(:search_results, results)
     |> assign(:search_loading, false)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) do
    {:noreply, assign(socket, :tab, tab)}
  end

  def handle_event("search", params, socket) do
    query = Map.get(params, "query", "")
    registry = Map.get(params, "registry", "")
    selected = if registry == "", do: nil, else: registry

    socket =
      socket
      |> assign(:search_loading, true)
      |> assign(:search_query, query)
      |> assign(:selected_registry, selected)

    send(self(), {:do_search, query, selected})
    {:noreply, socket}
  end

  def handle_event("select_registry", %{"registry" => registry}, socket) do
    selected = if registry == "", do: nil, else: registry
    {:noreply, assign(socket, :selected_registry, selected)}
  end

  def handle_event("toggle_all_registries", _params, socket) do
    {:noreply, assign(socket, :show_all_registries, !socket.assigns.show_all_registries)}
  end

  def handle_event("select_entry", %{"entry" => entry_json}, socket) do
    entry = parse_entry(entry_json)
    template = get_or_create_template_from_entry(entry)

    {:noreply,
     push_navigate(socket,
       to: ~p"/deploy/new?step=network&type=container&template_id=#{template.id}"
     )}
  end

  def handle_event("deploy_custom", %{"image" => image, "tag" => tag, "name" => name}, socket) do
    if image == "" or name == "" do
      {:noreply, put_flash(socket, :error, "Image and name are required.")}
    else
      full_image = if String.contains?(image, ":"), do: image, else: "#{image}:#{tag}"
      slug = "custom-#{slugify(name)}-#{System.unique_integer([:positive]) |> rem(10000)}"

      template_attrs = %{
        slug: slug,
        name: name,
        version: tag,
        image: full_image,
        description: "Custom deployment",
        source: "custom",
        source_id: full_image,
        required_env: [],
        default_env: %{},
        volumes: []
      }

      case Catalog.create_app_template(template_attrs) do
        {:ok, template} ->
          deploy_form =
            to_form(%{"tenant_id" => "", "domain" => "", "env_overrides" => %{}})

          {:noreply,
           socket
           |> assign(:selected_template, template)
           |> assign(:deploy_form, deploy_form)
           |> assign(:deploy_ports, template.ports || [])
           |> assign(:deploy_volumes, template.volumes || [])
           |> assign(:tab, "curated")}

        {:error, changeset} ->
          {:noreply, put_flash(socket, :error, "Failed to create: #{inspect(changeset.errors)}")}
      end
    end
  end

  def handle_event("close_deploy", _params, socket) do
    {:noreply,
     socket
     |> assign(:selected_template, nil)
     |> assign(:selected_entry, nil)}
  end

  def handle_event("add_port", _params, socket) do
    ports =
      (socket.assigns.deploy_ports || []) ++
        [
          %{
            "internal" => "",
            "external" => "",
            "description" => "",
            "optional" => "true",
            "role" => "other",
            "published" => false
          }
        ]

    {:noreply, assign(socket, :deploy_ports, ports)}
  end

  def handle_event("remove_port", %{"index" => idx}, socket) do
    ports = List.delete_at(socket.assigns.deploy_ports || [], String.to_integer(idx))
    {:noreply, assign(socket, :deploy_ports, ports)}
  end

  def handle_event("add_volume", _params, socket) do
    volumes =
      (socket.assigns.deploy_volumes || []) ++
        [%{"container_path" => "", "description" => "", "optional" => "true"}]

    {:noreply, assign(socket, :deploy_volumes, volumes)}
  end

  def handle_event("remove_volume", %{"index" => idx}, socket) do
    volumes = List.delete_at(socket.assigns.deploy_volumes || [], String.to_integer(idx))
    {:noreply, assign(socket, :deploy_volumes, volumes)}
  end

  def handle_event("add_env_var", _params, socket) do
    template = socket.assigns.selected_template
    default_env = template.default_env || %{}
    new_key = "NEW_VAR_#{map_size(default_env) + 1}"
    updated_env = Map.put(default_env, new_key, "")
    updated_template = struct(template, %{default_env: updated_env})
    deploy_form = build_deploy_form(updated_template)
    {:noreply, assign(socket, selected_template: updated_template, deploy_form: deploy_form)}
  end

  def handle_event("remove_env_var", %{"key" => key}, socket) do
    template = socket.assigns.selected_template
    default_env = Map.delete(template.default_env || %{}, key)
    required_env = Enum.reject(template.required_env || [], &(&1 == key))
    updated_template = struct(template, %{default_env: default_env, required_env: required_env})
    deploy_form = build_deploy_form(updated_template)
    {:noreply, assign(socket, selected_template: updated_template, deploy_form: deploy_form)}
  end

  def handle_event("deploy", %{"tenant_id" => tenant_id} = params, socket) do
    template = socket.assigns.selected_template

    env_overrides =
      (params["env_overrides"] || %{})
      |> Enum.reject(fn {_k, v} -> v == "" end)
      |> Map.new()

    ports = parse_port_params(params["ports"])
    volumes = parse_volume_params(params["volumes"])
    exposure_mode = params["exposure_mode"] || "public"

    template_updates = %{}

    template_updates =
      if ports != template.ports,
        do: Map.put(template_updates, :ports, ports),
        else: template_updates

    template_updates =
      if volumes != template.volumes,
        do: Map.put(template_updates, :volumes, volumes),
        else: template_updates

    template_updates =
      if exposure_mode != to_string(template.exposure_mode),
        do: Map.put(template_updates, :exposure_mode, String.to_existing_atom(exposure_mode)),
        else: template_updates

    if map_size(template_updates) > 0 do
      Catalog.update_app_template(template, template_updates)
    end

    attrs = %{
      tenant_id: String.to_integer(tenant_id),
      app_template_id: template.id,
      domain: params["domain"],
      env_overrides: env_overrides
    }

    case Homelab.Deployments.deploy_now(attrs) do
      {:ok, _deployment} ->
        {:noreply,
         socket
         |> assign(:selected_template, nil)
         |> assign(:selected_entry, nil)
         |> put_flash(:info, "#{template.name} deployment started!")}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, put_flash(socket, :error, "Deployment failed: #{inspect(changeset.errors)}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Deployment failed: #{inspect(reason)}")}
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
      <div>
        <div class="mb-5">
          <h1 class="text-2xl font-bold text-base-content">App Catalog</h1>
          <p class="mt-1 text-sm text-base-content/50">
            Browse curated apps, search registries, or deploy a custom image.
          </p>
        </div>

        <%!-- Tabs --%>
        <div class="flex gap-6 border-b border-base-content/10 mb-5">
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="curated"
            class={[
              "pb-2.5 text-sm font-medium -mb-px",
              if(@tab == "curated",
                do: "border-b-2 border-primary text-base-content",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            Curated
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="search"
            class={[
              "pb-2.5 text-sm font-medium -mb-px",
              if(@tab == "search",
                do: "border-b-2 border-primary text-base-content",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            Search
          </button>
          <button
            type="button"
            phx-click="switch_tab"
            phx-value-tab="custom"
            class={[
              "pb-2.5 text-sm font-medium -mb-px",
              if(@tab == "custom",
                do: "border-b-2 border-primary text-base-content",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            Custom
          </button>
        </div>

        <%!-- Curated tab --%>
        <div :if={@tab == "curated"} class="space-y-5">
          <div :if={@curated_entries == [] && connected?(@socket)} class="py-12 text-center">
            <div class="inline-flex items-center gap-2 text-base-content/50">
              <.icon name="hero-arrow-path" class="size-5 animate-spin" />
              <span>Loading curated catalog...</span>
            </div>
          </div>
          <div :if={@curated_entries == [] && !connected?(@socket)} class="py-12 text-center">
            <p class="text-base-content/50">Connect to load the catalog.</p>
          </div>
          <div :if={@curated_entries != []}>
            <div class="flex items-center justify-between mb-2">
              <p class="text-xs text-base-content/40">
                {filtered_entry_count(@curated_entries, @show_all_registries)} of {length(
                  @curated_entries
                )} apps shown
              </p>
              <button
                type="button"
                phx-click="toggle_all_registries"
                class={[
                  "inline-flex items-center gap-1.5 text-xs font-medium rounded-lg px-3 py-1.5 transition-colors",
                  if(@show_all_registries,
                    do: "bg-primary/10 text-primary",
                    else: "bg-base-200 text-base-content/50 hover:text-base-content/70"
                  )
                ]}
              >
                <.icon
                  name={if(@show_all_registries, do: "hero-eye-mini", else: "hero-eye-slash-mini")}
                  class="size-3.5"
                />
                {if(@show_all_registries, do: "Showing all registries", else: "Show all registries")}
              </button>
            </div>
            <div class="space-y-4">
              <%= for {category, entries} <- group_by_category(filter_by_registry(@curated_entries, @show_all_registries)) do %>
                <div>
                  <div class="flex items-baseline gap-2 mb-3">
                    <h2 class="text-xs font-semibold uppercase tracking-wider text-base-content/40">
                      {category}
                    </h2>
                    <span class="text-[10px] text-base-content/25">{length(entries)}</span>
                  </div>
                  <div class="grid grid-cols-1 sm:grid-cols-2 xl:grid-cols-3 gap-3">
                    <button
                      :for={entry <- entries}
                      type="button"
                      class={[
                        "text-left rounded-lg transition-all p-4 group border flex flex-col",
                        if(Homelab.Config.image_pullable?(entry.full_ref),
                          do:
                            "bg-base-100 border-base-content/5 hover:border-primary/20 hover:shadow-md",
                          else: "bg-base-100/50 border-warning/20 opacity-60"
                        )
                      ]}
                      phx-click="select_entry"
                      phx-value-entry={encode_entry(entry)}
                    >
                      <div class="flex items-start gap-3">
                        <div class="w-10 h-10 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0 overflow-hidden">
                          <img
                            :if={entry.logo_url}
                            src={entry.logo_url}
                            alt=""
                            class="w-full h-full object-contain"
                          />
                          <.icon
                            :if={!entry.logo_url}
                            name={app_icon(entry.name)}
                            class="size-5 text-primary"
                          />
                        </div>
                        <div class="min-w-0 flex-1">
                          <div class="flex items-center gap-2">
                            <h3 class="font-semibold text-sm text-base-content group-hover:text-primary transition-colors truncate">
                              {entry.name}
                            </h3>
                            <span
                              :if={!Homelab.Config.image_pullable?(entry.full_ref)}
                              class="flex-shrink-0"
                            >
                              <.icon
                                name="hero-lock-closed-mini"
                                class="size-3.5 text-warning/70"
                              />
                            </span>
                          </div>
                          <p class="text-xs text-base-content/35 mt-0.5 truncate">
                            {compact_source(entry)}
                          </p>
                        </div>
                      </div>
                      <p class="text-[13px] text-base-content/50 mt-2.5 line-clamp-2 leading-relaxed flex-1">
                        {entry.description || "No description available"}
                      </p>
                      <div class="flex items-center gap-1.5 mt-3 flex-wrap">
                        <span
                          :if={length(entry.required_ports) > 0}
                          class="text-[11px] font-semibold text-info bg-info/15 rounded px-2 py-0.5 inline-flex items-center gap-1"
                        >
                          <.icon name="hero-signal-mini" class="size-3.5" />
                          {length(entry.required_ports)}
                        </span>
                        <span
                          :if={length(entry.required_volumes) > 0}
                          class="text-[11px] font-semibold text-secondary bg-secondary/15 rounded px-2 py-0.5 inline-flex items-center gap-1"
                        >
                          <.icon name="hero-circle-stack-mini" class="size-3.5" />
                          {length(entry.required_volumes)}
                        </span>
                        <span
                          :if={registry_label(entry.full_ref) != "Docker Hub"}
                          class="text-[10px] font-semibold text-base-content/60 bg-base-content/10 rounded px-1.5 py-0.5"
                        >
                          {registry_label(entry.full_ref)}
                        </span>
                        <span
                          :if={Map.get(entry, :alt_sources, []) != []}
                          class="text-[10px] font-semibold text-base-content/60 bg-base-content/10 rounded px-1.5 py-0.5"
                          title={
                            Enum.map_join(
                              Map.get(entry, :alt_sources, []),
                              ", ",
                              &(&1[:source] || &1["source"])
                            )
                          }
                        >
                          +{length(Map.get(entry, :alt_sources, []))}
                        </span>
                      </div>
                    </button>
                  </div>
                </div>
              <% end %>
            </div>
          </div>
        </div>

        <%!-- Search tab --%>
        <div :if={@tab == "search"} class="space-y-4">
          <div class="flex flex-col sm:flex-row gap-4">
            <form phx-submit="search" class="flex-1 flex gap-3">
              <select
                name="registry"
                phx-change="select_registry"
                class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="">All registries</option>
                <option
                  :for={reg <- @registries}
                  value={reg.driver_id()}
                  selected={@selected_registry == reg.driver_id()}
                >
                  {reg.display_name()}
                </option>
              </select>
              <input
                type="text"
                name="query"
                value={@search_query}
                placeholder="Search images..."
                class="flex-1 rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
              />
              <button
                type="submit"
                class="px-4 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                Search
              </button>
            </form>
          </div>
          <div :if={@search_loading} class="py-8 text-center">
            <.icon name="hero-arrow-path" class="size-6 animate-spin text-base-content/40 mx-auto" />
          </div>
          <div :if={!@search_loading && @search_results != []} class="space-y-3">
            <div
              :for={entry <- @search_results}
              class="rounded-lg bg-base-100 p-4 border border-base-content/5 hover:border-primary/20 transition-colors"
            >
              <button
                type="button"
                class="w-full text-left"
                phx-click="select_entry"
                phx-value-entry={encode_entry(entry)}
              >
                <div class="flex items-start justify-between gap-4">
                  <div class="min-w-0 flex-1">
                    <div class="flex items-center gap-2 flex-wrap">
                      <span class="font-semibold text-base-content">{entry.name}</span>
                      <span class="text-[11px] font-medium text-base-content/40 bg-base-200 rounded-md px-2 py-0.5">
                        {source_badge(entry.source)}
                      </span>
                    </div>
                    <p :if={entry.namespace} class="text-xs text-base-content/40 mt-0.5">
                      {entry.namespace}
                    </p>
                    <p class="text-sm text-base-content/50 mt-1 line-clamp-2">
                      {entry.description || "No description"}
                    </p>
                    <div
                      :if={entry.stars > 0 || entry.pulls > 0}
                      class="flex gap-4 mt-2 text-xs text-base-content/40"
                    >
                      <span :if={entry.stars > 0}>★ {entry.stars}</span>
                      <span :if={entry.pulls > 0}>⬇ {entry.pulls}</span>
                    </div>
                  </div>
                  <.icon name="hero-chevron-right" class="size-5 text-base-content/30 flex-shrink-0" />
                </div>
              </button>
            </div>
          </div>
          <div
            :if={!@search_loading && @search_results == [] && @search_query != ""}
            class="py-12 text-center"
          >
            <p class="text-base-content/50">No results found.</p>
          </div>
        </div>

        <%!-- Custom tab --%>
        <div :if={@tab == "custom"} class="max-w-md">
          <.form
            for={@custom_form}
            id="custom-deploy-form"
            phx-submit="deploy_custom"
            class="space-y-5 rounded-lg bg-base-100 p-4 border border-base-content/5"
          >
            <.input
              field={@custom_form[:image]}
              type="text"
              label="Image"
              placeholder="nginx or ghcr.io/owner/repo"
            />
            <.input field={@custom_form[:tag]} type="text" label="Tag" placeholder="latest" />
            <.input field={@custom_form[:name]} type="text" label="Display name" placeholder="My App" />
            <button
              type="submit"
              class="w-full py-2.5 rounded-lg bg-primary text-primary-content font-medium"
            >
              Deploy
            </button>
          </.form>
        </div>

        <%!-- Deploy Modal --%>
        <div
          :if={@selected_template}
          id="deploy-modal"
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
          phx-window-keydown="close_deploy"
          phx-key="escape"
        >
          <div class="absolute inset-0 bg-black/60 backdrop-blur-sm" phx-click="close_deploy"></div>
          <div class="relative bg-base-100 rounded-lg shadow-2xl w-full max-w-lg max-h-[90vh] overflow-y-auto">
            <div class="p-4">
              <div class="flex items-center gap-5 mb-6">
                <div class="w-14 h-14 rounded-lg bg-primary/10 flex items-center justify-center overflow-hidden">
                  <img
                    :if={@selected_template.logo_url}
                    src={@selected_template.logo_url}
                    alt=""
                    class="w-full h-full object-contain"
                  />
                  <.icon
                    :if={!@selected_template.logo_url}
                    name={app_icon(@selected_template.slug)}
                    class="size-6 text-primary"
                  />
                </div>
                <div>
                  <h3 class="text-lg font-bold text-base-content">
                    Deploy {@selected_template.name}
                  </h3>
                  <div class="flex items-center gap-2 mt-1">
                    <p class="text-sm text-base-content/40">v{@selected_template.version}</p>
                    <.exposure_pill mode={@selected_template.exposure_mode} />
                  </div>
                </div>
              </div>

              <%!-- Requirements summary --%>
              <div
                :if={@enriching}
                class="mb-5 rounded-lg border border-base-content/10 bg-base-200/50 overflow-hidden"
              >
                <div class="px-4 py-3 border-b border-base-content/5">
                  <p class="text-xs font-semibold text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-arrow-path" class="size-3.5 animate-spin" />
                    Inspecting image and scanning repository...
                  </p>
                </div>
                <div class="p-4 space-y-3">
                  <div class="h-4 w-3/4 rounded bg-base-200 animate-pulse"></div>
                  <div class="h-4 w-1/2 rounded bg-base-200 animate-pulse"></div>
                  <div class="h-4 w-2/3 rounded bg-base-200 animate-pulse"></div>
                </div>
              </div>
              <.deploy_docs_link
                :if={!@enriching}
                entry={@selected_entry}
              />

              <.form for={@deploy_form} id="deploy-form" phx-submit="deploy" class="space-y-5">
                <%!-- Ports --%>
                <div class="space-y-2">
                  <p class="text-xs font-semibold text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-signal-mini" class="size-3.5" /> Ports
                  </p>
                  <div
                    :for={{port, idx} <- Enum.with_index(@deploy_ports)}
                    class="rounded-lg bg-base-200/50 p-3"
                  >
                    <div class="flex items-center gap-2 mb-2">
                      <span
                        :if={port["description"] && port["description"] != ""}
                        class="text-xs text-base-content/50"
                      >
                        {port["description"]}
                      </span>
                      <span class={[
                        "text-[10px] font-semibold rounded px-1.5 py-0.5 ml-auto",
                        if(port["optional"] == "true" || port["optional"] == true,
                          do: "bg-base-200 text-base-content/40",
                          else: "bg-warning/10 text-warning"
                        )
                      ]}>
                        {if(port["optional"] == "true" || port["optional"] == true,
                          do: "optional",
                          else: "required"
                        )}
                      </span>
                      <button
                        type="button"
                        phx-click="remove_port"
                        phx-value-index={idx}
                        class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                        title="Remove port"
                      >
                        <.icon name="hero-x-mark-mini" class="size-4" />
                      </button>
                    </div>
                    <div class="flex items-center gap-2">
                      <input
                        type="hidden"
                        name={"ports[#{idx}][description]"}
                        value={port["description"] || ""}
                      />
                      <input
                        type="hidden"
                        name={"ports[#{idx}][optional]"}
                        value={to_string(port["optional"] || false)}
                      />
                      <div class="flex-1">
                        <label class="block text-[10px] text-base-content/30 mb-0.5">Host</label>
                        <input
                          type="text"
                          name={"ports[#{idx}][external]"}
                          value={port["external"] || port["internal"]}
                          placeholder="8080"
                          class="w-full rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                        />
                      </div>
                      <span class="text-base-content/20 pt-4">:</span>
                      <div class="flex-1">
                        <label class="block text-[10px] text-base-content/30 mb-0.5">Container</label>
                        <input
                          type="text"
                          name={"ports[#{idx}][internal]"}
                          value={port["internal"] || ""}
                          placeholder="80"
                          class="w-full rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                        />
                      </div>
                      <div class="w-24">
                        <label class="block text-[10px] text-base-content/30 mb-0.5">Role</label>
                        <select
                          name={"ports[#{idx}][role]"}
                          class="w-full rounded-md bg-base-200 border-0 text-xs text-base-content py-1.5 px-1.5 focus:ring-2 focus:ring-primary/50"
                        >
                          <option
                            :for={
                              {label, value} <- Homelab.Catalog.Enrichers.PortRoles.available_roles()
                            }
                            value={value}
                            selected={value == (port["role"] || "other")}
                          >
                            {label}
                          </option>
                        </select>
                      </div>
                    </div>
                    <p
                      :if={(port["role"] || "other") == "web"}
                      class="text-[11px] text-info/70 mt-2 flex items-center gap-1"
                    >
                      <.icon name="hero-globe-alt-mini" class="size-3" />
                      When a domain is set, this port is routed through the reverse proxy and won't be published on the host.
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="add_port"
                    class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
                  >
                    <.icon name="hero-plus-mini" class="size-3.5" /> Add port
                  </button>
                </div>

                <%!-- Volumes --%>
                <div class="space-y-2">
                  <p class="text-xs font-semibold text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-circle-stack-mini" class="size-3.5" /> Volumes
                  </p>
                  <div
                    :for={{vol, idx} <- Enum.with_index(@deploy_volumes)}
                    class="rounded-lg bg-base-200/50 p-3"
                  >
                    <div class="flex items-center gap-2 mb-2">
                      <span
                        :if={vol["description"] && vol["description"] != ""}
                        class="text-xs text-base-content/50"
                      >
                        {vol["description"]}
                      </span>
                      <span class={[
                        "text-[10px] font-semibold rounded px-1.5 py-0.5 ml-auto",
                        if(vol["optional"] == "true" || vol["optional"] == true,
                          do: "bg-base-200 text-base-content/40",
                          else: "bg-warning/10 text-warning"
                        )
                      ]}>
                        {if(vol["optional"] == "true" || vol["optional"] == true,
                          do: "optional",
                          else: "required"
                        )}
                      </span>
                      <button
                        type="button"
                        phx-click="remove_volume"
                        phx-value-index={idx}
                        class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                        title="Remove volume"
                      >
                        <.icon name="hero-x-mark-mini" class="size-4" />
                      </button>
                    </div>
                    <div class="flex items-center gap-2">
                      <input
                        type="hidden"
                        name={"volumes[#{idx}][description]"}
                        value={vol["description"] || ""}
                      />
                      <input
                        type="hidden"
                        name={"volumes[#{idx}][optional]"}
                        value={to_string(vol["optional"] || false)}
                      />
                      <div class="flex-1">
                        <label class="block text-[10px] text-base-content/30 mb-0.5">
                          Container path
                        </label>
                        <input
                          type="text"
                          name={"volumes[#{idx}][container_path]"}
                          value={vol["path"] || vol["container_path"]}
                          placeholder="/data"
                          class="w-full rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-1.5 px-2.5 focus:ring-2 focus:ring-primary/50"
                        />
                      </div>
                    </div>
                  </div>
                  <button
                    type="button"
                    phx-click="add_volume"
                    class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
                  >
                    <.icon name="hero-plus-mini" class="size-3.5" /> Add volume
                  </button>
                </div>

                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1.5">Space</label>
                  <select
                    name="tenant_id"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                    required
                  >
                    <option value="" disabled selected>Select a space...</option>
                    <option :for={tenant <- @tenants} value={tenant.id}>
                      {tenant.name} ({tenant.slug})
                    </option>
                  </select>
                </div>

                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                    Domain <span class="font-normal text-base-content/30 ml-1">optional</span>
                  </label>
                  <input
                    type="text"
                    name="domain"
                    placeholder={"#{@selected_template.slug}.yourdomain.com"}
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
                  />
                  <p class="text-[11px] text-base-content/30 mt-1.5">
                    Setting a domain enables automatic reverse proxy via Traefik. The app will be accessible at this address on ports 80/443.
                  </p>
                </div>

                <div>
                  <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                    Exposure Mode <span class="font-normal text-base-content/30 ml-1">optional</span>
                  </label>
                  <select
                    name="exposure_mode"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                  >
                    <option value="public" selected>Public</option>
                    <option value="sso_protected">SSO Protected</option>
                    <option value="private">Private (LAN only)</option>
                    <option value="service">Service (proxy-only, no host ports)</option>
                  </select>
                </div>

                <%!-- Required env vars --%>
                <div :if={@selected_template.required_env != []} class="space-y-3">
                  <p class="text-xs font-semibold text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-key-mini" class="size-3.5" /> Required configuration
                  </p>
                  <div
                    :for={env <- @selected_template.required_env}
                    class="rounded-lg bg-base-200/50 p-3"
                  >
                    <div class="flex items-center justify-between mb-1">
                      <label class="text-xs font-medium text-base-content/50 font-mono">
                        {env}
                      </label>
                      <div class="flex items-center gap-1.5">
                        <span class="text-[10px] font-semibold rounded px-1.5 py-0.5 bg-warning/10 text-warning">
                          required
                        </span>
                        <button
                          type="button"
                          phx-click="remove_env_var"
                          phx-value-key={env}
                          class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                          title="Remove variable"
                        >
                          <.icon name="hero-x-mark-mini" class="size-4" />
                        </button>
                      </div>
                    </div>
                    <input
                      type={
                        if String.contains?(env, "PASSWORD") or String.contains?(env, "SECRET"),
                          do: "password",
                          else: "text"
                      }
                      name={"env_overrides[#{env}]"}
                      required
                      placeholder={"Enter #{humanize_env(env)}"}
                      class="w-full rounded-md bg-base-200 border-0 text-sm text-base-content py-1.5 px-2.5 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
                    />
                  </div>
                </div>

                <%!-- Default env vars (pre-filled, editable) --%>
                <div :if={map_size(@selected_template.default_env || %{}) > 0} class="space-y-3">
                  <p class="text-xs font-semibold text-base-content/60 flex items-center gap-1.5">
                    <.icon name="hero-cog-6-tooth-mini" class="size-3.5" /> Environment defaults
                  </p>
                  <div
                    :for={{key, val} <- @selected_template.default_env || %{}}
                    class="rounded-lg bg-base-200/50 p-3"
                  >
                    <div class="flex items-center justify-between mb-1">
                      <label class="text-xs font-medium text-base-content/50 font-mono">
                        {key}
                      </label>
                      <button
                        type="button"
                        phx-click="remove_env_var"
                        phx-value-key={key}
                        class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                        title="Remove variable"
                      >
                        <.icon name="hero-x-mark-mini" class="size-4" />
                      </button>
                    </div>
                    <input
                      type={
                        if String.contains?(key, "PASSWORD") or String.contains?(key, "SECRET"),
                          do: "password",
                          else: "text"
                      }
                      name={"env_overrides[#{key}]"}
                      value={val}
                      class="w-full rounded-md bg-base-200 border-0 text-sm text-base-content py-1.5 px-2.5 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
                    />
                  </div>
                </div>

                <button
                  type="button"
                  phx-click="add_env_var"
                  class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
                >
                  <.icon name="hero-plus-mini" class="size-3.5" /> Add variable
                </button>

                <div class="flex justify-end gap-3 pt-2">
                  <button
                    type="button"
                    phx-click="close_deploy"
                    class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/70 hover:bg-base-200 transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    type="submit"
                    class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
                  >
                    Deploy
                  </button>
                </div>
              </.form>
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp deduplicate_entries(entries) do
    entries
    |> Enum.group_by(&normalize_name/1)
    |> Enum.map(fn {_key, group} -> merge_duplicates(group) end)
  end

  defp normalize_name(entry) do
    (entry.name || "")
    |> String.downcase()
    |> String.replace(~r/[\s_\-]+/, "")
  end

  defp merge_duplicates([single]), do: single

  defp merge_duplicates(group) do
    primary =
      Enum.max_by(group, fn e ->
        length(e.required_ports) + length(e.required_volumes) + map_size(e.default_env) +
          if(e.description && e.description != "", do: 1, else: 0) +
          if(e.logo_url, do: 2, else: 0) +
          if(e.setup_url, do: 1, else: 0)
      end)

    alt_sources =
      group
      |> Enum.reject(&(&1.source == primary.source))
      |> Enum.map(fn e -> %{source: e.source, full_ref: e.full_ref} end)
      |> Enum.uniq_by(& &1.source)

    merged_categories =
      group
      |> Enum.flat_map(& &1.categories)
      |> Enum.uniq()

    primary
    |> Map.put(:alt_sources, alt_sources)
    |> Map.put(:categories, merged_categories)
  end

  defp compact_source(entry) do
    source_name = source_badge(entry.source)
    alt_count = length(Map.get(entry, :alt_sources, []))

    cond do
      alt_count > 0 ->
        "#{source_name} + #{alt_count} more"

      entry.namespace && entry.namespace != "" && entry.namespace != entry.source ->
        "#{source_name} / #{entry.namespace}"

      true ->
        source_name
    end
  end

  defp registry_label(full_ref) do
    case Homelab.Config.registry_for_image(full_ref) do
      "ghcr" -> "GHCR"
      "ecr" -> "ECR"
      "dockerhub" -> "Docker Hub"
      other -> other
    end
  end

  defp filter_by_registry(entries, true = _show_all), do: entries

  defp filter_by_registry(entries, false = _show_all) do
    available_ids = Homelab.Config.available_registry_ids()

    Enum.filter(entries, fn entry ->
      registry_id = Homelab.Config.registry_for_image(entry.full_ref)
      registry_id in available_ids
    end)
  end

  defp filtered_entry_count(entries, show_all) do
    length(filter_by_registry(entries, show_all))
  end

  defp group_by_category(entries) do
    entries
    |> Enum.group_by(fn e ->
      (e.categories || ["Other"])
      |> List.first("Other")
      |> short_category()
    end)
    |> Enum.sort_by(fn {cat, _} -> cat end)
  end

  defp short_category(cat) do
    cat
    |> String.split(" - ")
    |> List.last()
    |> String.trim()
  end

  defp source_badge(source) when is_binary(source) do
    all_drivers = Homelab.Config.registries() ++ Homelab.Config.application_catalogs()

    case Enum.find(all_drivers, fn mod ->
           function_exported?(mod, :driver_id, 0) and mod.driver_id() == source
         end) do
      nil -> source
      mod -> mod.display_name()
    end
  end

  defp source_badge(source), do: to_string(source)

  defp encode_entry(entry) do
    entry
    |> Map.from_struct()
    |> Map.put(:source, to_string(entry.source))
    |> Jason.encode!()
  end

  defp parse_entry(json) do
    data = Jason.decode!(json)

    struct(CatalogEntry, %{
      name: data["name"],
      namespace: data["namespace"],
      description: data["description"],
      logo_url: data["logo_url"],
      version: data["version"],
      source: data["source"],
      full_ref: data["full_ref"],
      project_url: data["project_url"],
      setup_url: data["setup_url"],
      categories: data["categories"] || [],
      architectures: data["architectures"] || [],
      required_ports: data["required_ports"] || [],
      required_volumes: data["required_volumes"] || [],
      default_env: data["default_env"] || %{},
      required_env: data["required_env"] || [],
      alt_sources: data["alt_sources"] || [],
      stars: data["stars"] || 0,
      pulls: data["pulls"] || 0,
      official?: data["official?"] || false,
      deprecated?: data["deprecated?"] || false,
      auth_required?: data["auth_required?"] || false
    })
  end

  defp build_deploy_form(template) do
    all_env_keys =
      Map.keys(template.default_env || %{}) ++ (template.required_env || [])

    env_defaults =
      all_env_keys
      |> Enum.uniq()
      |> Enum.map(fn key ->
        {key, Map.get(template.default_env || %{}, key, "")}
      end)
      |> Map.new()

    to_form(%{
      "tenant_id" => "",
      "domain" => "",
      "env_overrides" => env_defaults
    })
  end

  defp update_template_from_enrichment(template, enriched_entry) do
    existing_volumes = template.volumes || []
    existing_ports = template.ports || []
    existing_default_env = template.default_env || %{}
    existing_required_env = template.required_env || []

    enriched_volumes =
      Enum.map(enriched_entry.required_volumes, fn vol ->
        %{
          "container_path" => vol["path"] || vol["container_path"],
          "description" => vol["description"]
        }
      end)

    enriched_ports =
      Enum.map(enriched_entry.required_ports, fn port ->
        %{
          "internal" => port["internal"],
          "external" => port["external"],
          "description" => port["description"],
          "role" => port["role"] || "other",
          "optional" => port["optional"] || false,
          "published" => port["published"] || false
        }
      end)

    existing_vol_paths = MapSet.new(existing_volumes, fn v -> v["container_path"] end)

    new_volumes =
      Enum.reject(enriched_volumes, fn v ->
        MapSet.member?(existing_vol_paths, v["container_path"])
      end)

    merged_volumes = existing_volumes ++ new_volumes

    existing_port_internals = MapSet.new(existing_ports, fn p -> p["internal"] end)

    new_ports =
      Enum.reject(enriched_ports, fn p ->
        MapSet.member?(existing_port_internals, p["internal"])
      end)

    merged_ports = existing_ports ++ new_ports

    merged_default_env = Map.merge(enriched_entry.default_env, existing_default_env)

    all_known_keys = MapSet.new(Map.keys(existing_default_env) ++ existing_required_env)
    new_required = Enum.reject(enriched_entry.required_env, &MapSet.member?(all_known_keys, &1))
    merged_required_env = existing_required_env ++ new_required

    struct(template, %{
      volumes: merged_volumes,
      ports: merged_ports,
      default_env: merged_default_env,
      required_env: merged_required_env
    })
  end

  defp get_or_create_template_from_entry(entry) do
    slug = entry_slug(entry)

    case Catalog.get_app_template_by_slug(slug) do
      {:ok, template} ->
        template

      {:error, :not_found} ->
        image_slug =
          entry.name
          |> String.downcase()
          |> String.replace(~r/[^a-z0-9._-]+/, "-")
          |> String.trim("-")

        image =
          cond do
            entry.full_ref && entry.full_ref != "" -> entry.full_ref
            entry.namespace -> "#{entry.namespace}/#{image_slug}:latest"
            true -> "#{image_slug}:latest"
          end

        volumes =
          Enum.map(entry.required_volumes, fn vol ->
            %{"container_path" => vol["path"], "description" => vol["description"]}
          end)

        ports =
          Enum.map(entry.required_ports, fn port ->
            %{
              "internal" => port["internal"],
              "external" => port["external"],
              "description" => port["description"],
              "role" => port["role"] || "other",
              "optional" => port["optional"] || false,
              "published" => port["published"] || false
            }
          end)

        attrs = %{
          slug: slug,
          name: entry.name,
          version: entry.version || "latest",
          image: image,
          description: entry.description,
          source: to_string(entry.source),
          source_id: entry.full_ref,
          logo_url: entry.logo_url,
          category: List.first(entry.categories || []),
          required_env: entry.required_env || [],
          default_env: entry.default_env || %{},
          volumes: volumes,
          ports: ports
        }

        case Catalog.create_app_template(attrs) do
          {:ok, template} -> template
          {:error, _} -> raise "Failed to create template"
        end
    end
  end

  defp entry_slug(entry) do
    base =
      entry.name
      |> String.downcase()
      |> String.replace("/", "-")
      |> String.replace(~r/[^a-z0-9-]/, "-")
      |> String.replace(~r/-+/, "-")
      |> String.trim("-")

    if base == "" or String.length(base) < 2, do: "custom-app", else: base
  end

  defp parse_port_params(nil), do: []

  defp parse_port_params(ports_map) when is_map(ports_map) do
    ports_map
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, port} ->
      %{
        "internal" => port["internal"],
        "external" => port["external"],
        "description" => port["description"],
        "optional" => port["optional"] == "true",
        "role" => port["role"] || "other",
        "published" => port["published"] == "true"
      }
    end)
  end

  defp parse_volume_params(nil), do: []

  defp parse_volume_params(volumes_map) when is_map(volumes_map) do
    volumes_map
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, vol} ->
      %{
        "container_path" => vol["container_path"],
        "description" => vol["description"],
        "optional" => vol["optional"] == "true"
      }
    end)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  defp deploy_docs_link(assigns) do
    entry = assigns.entry
    setup_url = if(entry, do: entry.setup_url, else: nil)
    project_url = if(entry, do: entry.project_url, else: nil)

    has_config =
      length(if(entry, do: entry.required_ports || [], else: [])) > 0 or
        length(if(entry, do: entry.required_volumes || [], else: [])) > 0

    assigns =
      assigns
      |> assign(:setup_url, setup_url)
      |> assign(:project_url, project_url)
      |> assign(:has_config, has_config)

    ~H"""
    <div
      :if={!@has_config && (@setup_url || @project_url)}
      class="mb-5 rounded-lg border border-info/20 bg-info/5 p-4"
    >
      <div class="flex items-start gap-2.5">
        <.icon name="hero-book-open-mini" class="size-4 text-info/70 mt-0.5 flex-shrink-0" />
        <div>
          <p class="text-sm font-medium text-base-content/70">
            No ports or volumes auto-detected
          </p>
          <p class="text-xs text-base-content/40 mt-1 leading-relaxed">
            Check the docs for any setup requirements before deploying.
          </p>
          <div class="flex items-center gap-3 mt-2">
            <a
              :if={@setup_url}
              href={@setup_url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1.5 text-xs font-semibold text-primary hover:text-primary/80 transition-colors"
            >
              <.icon name="hero-book-open-mini" class="size-3.5" /> Setup guide
              <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
            </a>
            <a
              :if={@project_url}
              href={@project_url}
              target="_blank"
              rel="noopener noreferrer"
              class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/50 hover:text-base-content/70 transition-colors"
            >
              <.icon name="hero-code-bracket-mini" class="size-3.5" /> Project page
              <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
            </a>
          </div>
        </div>
      </div>
    </div>

    <div
      :if={@has_config && (@setup_url || @project_url)}
      class="mb-4 flex items-center gap-3"
    >
      <a
        :if={@setup_url}
        href={@setup_url}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors"
      >
        <.icon name="hero-book-open-mini" class="size-3.5" /> Setup guide
        <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
      </a>
      <a
        :if={@project_url}
        href={@project_url}
        target="_blank"
        rel="noopener noreferrer"
        class="inline-flex items-center gap-1.5 text-xs font-medium text-base-content/50 hover:text-base-content/70 transition-colors"
      >
        <.icon name="hero-code-bracket-mini" class="size-3.5" /> Project page
        <.icon name="hero-arrow-top-right-on-square-mini" class="size-3" />
      </a>
    </div>
    """
  end

  defp exposure_pill(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[11px] font-medium rounded-md px-2 py-0.5",
      exposure_classes(@mode)
    ]}>
      <.icon name={exposure_icon(@mode)} class="size-3" />
      {format_exposure(@mode)}
    </span>
    """
  end

  defp exposure_classes(:private), do: "bg-base-200 text-base-content/40"
  defp exposure_classes(:sso_protected), do: "bg-success/10 text-success"
  defp exposure_classes(:public), do: "bg-warning/10 text-warning"
  defp exposure_classes(:service), do: "bg-info/10 text-info"
  defp exposure_classes(_), do: "bg-base-200 text-base-content/40"

  defp exposure_icon(:private), do: "hero-lock-closed-mini"
  defp exposure_icon(:sso_protected), do: "hero-shield-check-mini"
  defp exposure_icon(:public), do: "hero-globe-alt-mini"
  defp exposure_icon(:service), do: "hero-server-stack-mini"
  defp exposure_icon(_), do: "hero-question-mark-circle-mini"

  defp format_exposure(:sso_protected), do: "SSO"
  defp format_exposure(:private), do: "Private"
  defp format_exposure(:public), do: "Public"
  defp format_exposure(:service), do: "Service"
  defp format_exposure(mode), do: to_string(mode)

  defp app_icon("nextcloud"), do: "hero-cloud"
  defp app_icon("immich"), do: "hero-photo"
  defp app_icon("jellyfin"), do: "hero-film"
  defp app_icon("vaultwarden"), do: "hero-key"
  defp app_icon("gitea"), do: "hero-code-bracket"
  defp app_icon("uptime-kuma"), do: "hero-chart-bar"
  defp app_icon("paperless-ngx"), do: "hero-document-text"
  defp app_icon("mealie"), do: "hero-cake"
  defp app_icon("wireguard"), do: "hero-shield-check"
  defp app_icon("freshrss"), do: "hero-rss"
  defp app_icon(_), do: "hero-cube"

  defp humanize_env(env_var) do
    env_var
    |> String.downcase()
    |> String.replace("_", " ")
  end
end
