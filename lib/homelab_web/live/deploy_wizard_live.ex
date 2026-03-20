defmodule HomelabWeb.DeployWizardLive do
  use HomelabWeb, :live_view

  alias Homelab.Catalog
  alias Homelab.Catalog.CatalogEntry
  alias Homelab.Catalog.MetadataEnricher
  alias Homelab.Catalog.Enrichers.ComposeParser
  alias Homelab.Catalog.Enrichers.DatabaseDetector
  alias Homelab.Catalog.Enrichers.InfraDetector
  alias Homelab.Tenants

  @steps ~w(type app network config review)

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()
    registries = Homelab.Config.registries()
    catalogs = Homelab.Config.application_catalogs()

    socket =
      socket
      |> assign(:page_title, "New Deployment")
      |> assign(:step, "type")
      |> assign(:deploy_type, nil)
      |> assign(:tenants, tenants)
      |> assign(:registries, registries)
      |> assign(:catalogs, catalogs)
      |> assign(:search_query, "")
      |> assign(:search_results, [])
      |> assign(:search_loading, false)
      |> assign(:curated_entries, [])
      |> assign(:curated_loading, false)
      |> assign(:selected_entry, nil)
      |> assign(:selected_template, nil)
      |> assign(:enriching, nil)
      |> assign(:custom_image, "")
      |> assign(:custom_name, "")
      |> assign(:compose_yaml, "")
      |> assign(:compose_services, [])
      |> assign(:compose_error, nil)
      |> assign(:ports, [])
      |> assign(:volumes, [])
      |> assign(:env_vars, [])
      |> assign(:db_suggestions, [])
      |> assign(:infra_suggestions, [])
      |> assign(:view_mode, :form)
      |> assign(:companion_query, "")
      |> assign(:companion_results, [])
      |> assign(:companion_loading, false)
      |> assign(:domain, "")
      |> assign(:exposure_mode, "public")
      |> assign(:tenant_id, nil)

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    step = params["step"] || "type"
    step = if step in @steps, do: step, else: "type"

    already_loaded = socket.assigns.selected_template != nil

    socket =
      socket
      |> assign(:step, step)
      |> maybe_load_from_params(params, already_loaded)
      |> maybe_prefill_from_domain(step)

    {:noreply, socket}
  end

  defp maybe_load_from_params(socket, %{"template_id" => tid}, false = _already_loaded) do
    case Catalog.get_app_template(String.to_integer(tid)) do
      {:ok, template} ->
        env_vars = build_env_var_list(template.default_env || %{}, template.required_env || [])

        if connected?(socket) and template.image != nil and template.image != "" do
          start_enrichment_for_template(template)
        end

        socket
        |> assign(:deploy_type, "container")
        |> assign(:selected_template, template)
        |> assign(:ports, template.ports || [])
        |> assign(:volumes, template.volumes || [])
        |> assign(:env_vars, env_vars)
        |> assign(:enriching, if(connected?(socket), do: "inspecting", else: nil))
        |> assign(
          :step,
          if(socket.assigns.step == "type", do: "network", else: socket.assigns.step)
        )
        |> recompute_suggestions()

      {:error, _} ->
        socket
    end
  end

  defp maybe_load_from_params(socket, %{"type" => type}, _already_loaded)
       when type in ~w(container compose stack) do
    if socket.assigns.deploy_type == nil do
      assign(socket, :deploy_type, type)
    else
      socket
    end
  end

  defp maybe_load_from_params(socket, _params, _already_loaded), do: socket

  @app_url_keys ~w(APP_URL BASE_URL SITE_URL APPLICATION_URL NEXTAUTH_URL APP_DOMAIN SERVER_URL)

  defp maybe_prefill_from_domain(socket, "config") do
    domain = socket.assigns[:domain] || ""

    if domain != "" and socket.assigns.selected_template != nil do
      url = "https://#{domain}"

      env_vars =
        Enum.map(socket.assigns.env_vars, fn env ->
          if env["key"] in @app_url_keys and (env["value"] == nil or env["value"] == "") do
            Map.put(env, "value", url)
          else
            env
          end
        end)

      socket
      |> assign(:env_vars, env_vars)
      |> recompute_suggestions()
    else
      recompute_suggestions(socket)
    end
  end

  defp maybe_prefill_from_domain(socket, _step), do: socket

  defp start_enrichment_for_template(template) do
    pid = self()

    Task.start(fn ->
      entry = %CatalogEntry{
        name: template.name,
        full_ref: template.image,
        project_url: nil,
        source: template.source || "custom",
        default_env: template.default_env || %{},
        required_env: template.required_env || [],
        required_ports:
          Enum.map(template.ports || [], fn p ->
            %{
              "internal" => p["internal"],
              "external" => p["external"],
              "description" => p["description"],
              "role" => p["role"],
              "optional" => p["optional"]
            }
          end),
        required_volumes:
          Enum.map(template.volumes || [], fn v ->
            %{"path" => v["container_path"], "description" => v["description"]}
          end),
        categories: [template.category],
        stars: 0,
        pulls: 0
      }

      {:ok, enriched} = MetadataEnricher.enrich(entry, progress: pid)
      send(pid, {:enrichment_complete, enriched})
    end)
  end

  # --- Events: Step navigation ---

  @impl true
  def handle_event("select_type", %{"type" => type}, socket) do
    socket = assign(socket, :deploy_type, type)
    {:noreply, push_patch(socket, to: ~p"/deploy/new?step=app&type=#{type}")}
  end

  def handle_event("go_step", %{"step" => step}, socket) do
    params = build_step_params(socket, step)
    {:noreply, push_patch(socket, to: ~p"/deploy/new?#{params}")}
  end

  def handle_event("back", _params, socket) do
    prev = prev_step(socket.assigns.step)
    params = build_step_params(socket, prev)
    {:noreply, push_patch(socket, to: ~p"/deploy/new?#{params}")}
  end

  # --- Events: App selection ---

  def handle_event("search", %{"query" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply, assign(socket, search_results: [], search_query: "")}
    else
      send(self(), {:do_search, query})
      {:noreply, assign(socket, search_loading: true, search_query: query)}
    end
  end

  def handle_event("load_curated", _params, socket) do
    send(self(), :load_curated)
    {:noreply, assign(socket, :curated_loading, true)}
  end

  def handle_event("select_entry", %{"entry" => entry_json}, socket) do
    entry = parse_entry(entry_json)
    template = get_or_create_template_from_entry(entry)
    env_vars = build_env_var_list(template.default_env || %{}, template.required_env || [])

    pid = self()

    Task.start(fn ->
      {:ok, enriched} = MetadataEnricher.enrich(entry, progress: pid)
      send(pid, {:enrichment_complete, enriched})
    end)

    socket =
      socket
      |> assign(:selected_entry, entry)
      |> assign(:selected_template, template)
      |> assign(:ports, template.ports || [])
      |> assign(:volumes, template.volumes || [])
      |> assign(:env_vars, env_vars)
      |> assign(:enriching, "inspecting")

    params = build_step_params(socket, "config")
    {:noreply, push_patch(socket, to: ~p"/deploy/new?#{params}")}
  end

  def handle_event("select_custom", %{"image" => image, "name" => name}, socket) do
    image = String.trim(image)
    name = String.trim(name)

    if image == "" do
      {:noreply, put_flash(socket, :error, "Image is required")}
    else
      display_name = if name == "", do: image_display_name(image), else: name
      slug = slugify(display_name)

      template_attrs = %{
        slug: slug,
        name: display_name,
        version: "latest",
        image: image,
        description: "Custom deployment",
        source: "custom",
        source_id: image,
        required_env: [],
        default_env: %{},
        volumes: [],
        ports: []
      }

      template =
        case Catalog.get_app_template_by_slug(slug) do
          {:ok, t} ->
            t

          {:error, :not_found} ->
            case Catalog.create_app_template(template_attrs) do
              {:ok, t} -> t
              {:error, _} -> struct(Homelab.Catalog.AppTemplate, template_attrs)
            end
        end

      pid = self()

      if image != "" do
        Task.start(fn ->
          entry = %CatalogEntry{
            name: display_name,
            full_ref: image,
            default_env: %{},
            required_env: [],
            required_ports: [],
            required_volumes: [],
            categories: [],
            stars: 0,
            pulls: 0
          }

          {:ok, enriched} = MetadataEnricher.enrich(entry, progress: pid)
          send(pid, {:enrichment_complete, enriched})
        end)
      end

      socket =
        socket
        |> assign(:selected_template, template)
        |> assign(:ports, template.ports || [])
        |> assign(:volumes, template.volumes || [])
        |> assign(
          :env_vars,
          build_env_var_list(template.default_env || %{}, template.required_env || [])
        )
        |> assign(:enriching, if(image != "", do: "inspecting", else: nil))

      params = build_step_params(socket, "config")
      {:noreply, push_patch(socket, to: ~p"/deploy/new?#{params}")}
    end
  end

  # --- Events: Compose ---

  def handle_event("parse_compose", %{"compose_yaml" => yaml}, socket) do
    socket = assign(socket, :compose_yaml, yaml)

    case ComposeParser.parse_all(yaml) do
      {:ok, services} when services != [] ->
        env_vars =
          services
          |> Enum.flat_map(fn svc -> svc[:env] || [] end)
          |> Enum.uniq_by(fn %{"key" => k} -> k end)
          |> Enum.map(fn %{"key" => k, "value" => v} ->
            %{"key" => k, "value" => v, "required" => v == ""}
          end)

        ports =
          services
          |> Enum.flat_map(fn svc -> svc[:ports] || [] end)
          |> Enum.uniq_by(fn p -> p["internal"] end)

        volumes =
          services
          |> Enum.flat_map(fn svc -> svc[:volumes] || [] end)
          |> Enum.uniq_by(fn v -> v["path"] end)

        socket =
          socket
          |> assign(:compose_services, services)
          |> assign(:compose_error, nil)
          |> assign(:ports, ports)
          |> assign(:volumes, volumes)
          |> assign(:env_vars, env_vars)

        params = build_step_params(socket, "config")
        {:noreply, push_patch(socket, to: ~p"/deploy/new?#{params}")}

      {:ok, []} ->
        {:noreply,
         assign(socket, compose_error: "No services found in compose file", compose_services: [])}

      {:error, reason} ->
        {:noreply,
         assign(socket,
           compose_error: "Failed to parse: #{inspect(reason)}",
           compose_services: []
         )}
    end
  end

  # --- Events: Configuration ---

  def handle_event("add_port", _params, socket) do
    ports =
      socket.assigns.ports ++
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

    {:noreply, assign(socket, :ports, ports)}
  end

  def handle_event("remove_port", %{"index" => idx}, socket) do
    ports = List.delete_at(socket.assigns.ports, String.to_integer(idx))
    {:noreply, assign(socket, :ports, ports)}
  end

  def handle_event("add_volume", _params, socket) do
    volumes =
      socket.assigns.volumes ++
        [%{"container_path" => "", "description" => "", "optional" => "true"}]

    {:noreply, assign(socket, :volumes, volumes)}
  end

  def handle_event("remove_volume", %{"index" => idx}, socket) do
    volumes = List.delete_at(socket.assigns.volumes, String.to_integer(idx))
    {:noreply, assign(socket, :volumes, volumes)}
  end

  def handle_event("add_env_var", _params, socket) do
    env_vars = socket.assigns.env_vars ++ [%{"key" => "", "value" => "", "required" => false}]
    {:noreply, assign(socket, :env_vars, env_vars)}
  end

  def handle_event("remove_env_var", %{"index" => idx}, socket) do
    env_vars = List.delete_at(socket.assigns.env_vars, String.to_integer(idx))
    {:noreply, assign(socket, :env_vars, env_vars)}
  end

  # --- Events: Database suggestions ---

  def handle_event("wire_db_secrets", %{"db-type" => db_type_str}, socket) do
    db_type = String.to_existing_atom(db_type_str)
    suggestion = Enum.find(socket.assigns.db_suggestions, &(&1.db_type == db_type))

    if suggestion do
      shared_password = DatabaseDetector.generate_secret(24)

      env_vars =
        Enum.map(socket.assigns.env_vars, fn env ->
          case Map.get(suggestion.wiring, env["key"]) do
            nil ->
              env

            value ->
              actual =
                if sensitive_key?(env["key"]),
                  do: shared_password,
                  else: value

              %{env | "value" => actual}
          end
        end)

      {:noreply,
       socket
       |> assign(:env_vars, env_vars)
       |> recompute_suggestions()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("add_companion_db", %{"db-type" => db_type_str}, socket) do
    db_type = String.to_existing_atom(db_type_str)
    suggestion = Enum.find(socket.assigns.db_suggestions, &(&1.db_type == db_type))

    if suggestion do
      shared_password = DatabaseDetector.generate_secret(24)

      companion_env =
        Map.new(suggestion.companion_env, fn {k, v} ->
          if sensitive_key?(k), do: {k, shared_password}, else: {k, v}
        end)

      env_vars =
        Enum.map(socket.assigns.env_vars, fn env ->
          case Map.get(suggestion.wiring, env["key"]) do
            nil ->
              env

            value ->
              actual =
                if sensitive_key?(env["key"]),
                  do: shared_password,
                  else: value

              %{env | "value" => actual}
          end
        end)

      companion_slug = "#{db_type}-companion"
      companion_name = "#{suggestion.label} (companion)"

      companion_env_list =
        Enum.map(companion_env, fn {k, v} ->
          %{"key" => k, "value" => v, "required" => true}
        end)

      companion_service = %{
        name: companion_slug,
        image: suggestion.image,
        ports: suggestion.companion_ports,
        volumes: suggestion.companion_volumes,
        env: companion_env_list,
        depends_on: []
      }

      compose_services = socket.assigns.compose_services ++ [companion_service]

      {:noreply,
       socket
       |> assign(:env_vars, env_vars)
       |> assign(:compose_services, compose_services)
       |> assign(
         :deploy_type,
         if(socket.assigns.deploy_type == "container",
           do: "compose",
           else: socket.assigns.deploy_type
         )
       )
       |> put_flash(
         :info,
         "#{companion_name} will be deployed alongside your app with shared credentials."
       )
       |> recompute_suggestions()}
    else
      {:noreply, socket}
    end
  end

  def handle_event("companion_search", %{"value" => query}, socket) do
    if String.trim(query) == "" do
      {:noreply,
       assign(socket, companion_results: [], companion_query: "", companion_loading: false)}
    else
      send(self(), {:do_companion_search, query})
      {:noreply, assign(socket, companion_loading: true, companion_query: query)}
    end
  end

  def handle_event("add_companion_entry", %{"entry" => entry_json}, socket) do
    entry = parse_entry(entry_json)

    slug =
      entry.name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    already_added =
      Enum.any?(socket.assigns.compose_services, fn svc -> svc[:name] == slug end)

    if already_added do
      {:noreply, put_flash(socket, :error, "#{entry.name} is already added.")}
    else
      ports =
        Enum.map(entry.required_ports || [], fn p ->
          %{
            "internal" => p["internal"] || to_string(p[:internal]),
            "external" => p["external"] || to_string(p[:external]),
            "role" => p["role"] || p[:role] || "other",
            "description" => p["description"] || p[:description] || "",
            "published" => false
          }
        end)

      volumes =
        Enum.map(entry.required_volumes || [], fn v ->
          %{
            "container_path" => v["path"] || v[:path] || v["container_path"] || "/data",
            "description" => v["description"] || v[:description] || ""
          }
        end)

      env =
        Enum.map(entry.default_env || %{}, fn {k, v} ->
          %{"key" => k, "value" => v, "required" => false}
        end)

      companion_service = %{
        name: slug,
        image: entry.full_ref,
        ports: ports,
        volumes: volumes,
        env: env,
        depends_on: []
      }

      compose_services = socket.assigns.compose_services ++ [companion_service]

      {:noreply,
       socket
       |> assign(:compose_services, compose_services)
       |> assign(:companion_query, "")
       |> assign(:companion_results, [])
       |> assign(
         :deploy_type,
         if(socket.assigns.deploy_type == "container",
           do: "compose",
           else: socket.assigns.deploy_type
         )
       )
       |> put_flash(:info, "#{entry.name} added as a companion service.")
       |> recompute_suggestions()}
    end
  end

  def handle_event("add_companion_custom", %{"image" => image}, socket) do
    image = String.trim(image)

    if image == "" do
      {:noreply, socket}
    else
      slug = image |> String.split("/") |> List.last() |> String.split(":") |> hd()

      already_added =
        Enum.any?(socket.assigns.compose_services, fn svc -> svc[:name] == slug end)

      if already_added do
        {:noreply, put_flash(socket, :error, "#{slug} is already added.")}
      else
        companion_service = %{
          name: slug,
          image: image,
          ports: [],
          volumes: [],
          env: [],
          depends_on: []
        }

        compose_services = socket.assigns.compose_services ++ [companion_service]

        {:noreply,
         socket
         |> assign(:compose_services, compose_services)
         |> assign(:companion_query, "")
         |> assign(:companion_results, [])
         |> assign(
           :deploy_type,
           if(socket.assigns.deploy_type == "container",
             do: "compose",
             else: socket.assigns.deploy_type
           )
         )
         |> put_flash(:info, "#{slug} added as a companion service.")
         |> recompute_suggestions()}
      end
    end
  end

  def handle_event("remove_companion_service", %{"name" => name}, socket) do
    compose_services =
      Enum.reject(socket.assigns.compose_services, fn svc -> svc[:name] == name end)

    deploy_type =
      if compose_services == [] and socket.assigns.deploy_type == "compose",
        do: "container",
        else: socket.assigns.deploy_type

    {:noreply,
     socket
     |> assign(:compose_services, compose_services)
     |> assign(:deploy_type, deploy_type)
     |> recompute_suggestions()}
  end

  def handle_event("apply_infra", %{"infra-id" => infra_id_str}, socket) do
    infra_id = String.to_existing_atom(infra_id_str)
    suggestion = Enum.find(socket.assigns.infra_suggestions, &(&1.id == infra_id))

    if suggestion && suggestion.fills != %{} do
      env_vars =
        Enum.map(socket.assigns.env_vars, fn env ->
          case Map.get(suggestion.fills, env["key"]) do
            nil -> env
            value -> %{env | "value" => value}
          end
        end)

      {:noreply,
       socket
       |> assign(:env_vars, env_vars)
       |> recompute_suggestions()
       |> put_flash(:info, "#{suggestion.label} values applied.")}
    else
      {:noreply, socket}
    end
  end

  def handle_event("toggle_view_mode", _params, socket) do
    new_mode = if socket.assigns.view_mode == :form, do: :visual, else: :form
    {:noreply, assign(socket, :view_mode, new_mode)}
  end

  def handle_event(
        "topology_change",
        %{"node_id" => _node_id, "key" => key, "value" => value},
        socket
      ) do
    socket =
      case key do
        "exposure" -> assign(socket, :exposure_mode, value)
        _ -> socket
      end

    {:noreply, socket}
  end

  def handle_event("topology_add", %{"column" => column}, socket) do
    case column do
      "infrastructure" ->
        {:noreply, put_flash(socket, :info, "Use the config step to add companion databases.")}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("topology_remove", %{"node-id" => _node_id}, socket) do
    {:noreply, socket}
  end

  def handle_event("apply_all_infra", _params, socket) do
    all_fills =
      socket.assigns.infra_suggestions
      |> Enum.flat_map(fn s -> Map.to_list(s.fills) end)
      |> Map.new()

    env_vars =
      Enum.map(socket.assigns.env_vars, fn env ->
        case Map.get(all_fills, env["key"]) do
          nil -> env
          value -> %{env | "value" => value}
        end
      end)

    {:noreply,
     socket
     |> assign(:env_vars, env_vars)
     |> recompute_suggestions()
     |> put_flash(:info, "All infrastructure values applied.")}
  end

  # --- Events: Network ---

  def handle_event("update_network", %{"network" => network_params} = _params, socket) do
    socket =
      socket
      |> assign(:domain, network_params["domain"] || socket.assigns.domain)
      |> assign(:tenant_id, non_blank(network_params["tenant_id"]) || socket.assigns.tenant_id)

    {:noreply, socket}
  end

  def handle_event("update_network", params, socket) do
    socket =
      socket
      |> assign(:exposure_mode, params["exposure_mode"] || socket.assigns.exposure_mode)

    {:noreply, socket}
  end

  # --- Events: Deploy ---

  def handle_event("deploy", params, socket) do
    tenant_id = params["tenant_id"] || socket.assigns.tenant_id
    domain = params["domain"] || socket.assigns.domain
    exposure_mode = params["exposure_mode"] || socket.assigns.exposure_mode

    if tenant_id == nil or tenant_id == "" do
      {:noreply, put_flash(socket, :error, "Please select a space.")}
    else
      template = socket.assigns.selected_template

      env_overrides = build_env_overrides(params)
      ports = parse_port_params(params["ports"])
      volumes = parse_volume_params(params["volumes"])

      template_updates =
        %{
          ports: ports,
          volumes: volumes,
          exposure_mode: String.to_existing_atom(exposure_mode)
        }

      if template.id do
        Catalog.update_app_template(template, template_updates)
      end

      attrs = %{
        tenant_id: String.to_integer(tenant_id),
        app_template_id: template.id,
        domain: domain,
        env_overrides: env_overrides
      }

      case Homelab.Deployments.deploy_now(attrs) do
        {:ok, _deployment} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{template.name} deployment started!")
           |> push_navigate(to: ~p"/")}

        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply, put_flash(socket, :error, "Deployment failed: #{inspect(changeset.errors)}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Deployment failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("deploy_compose", params, socket) do
    tenant_id = params["tenant_id"] || socket.assigns.tenant_id
    domain = params["domain"] || socket.assigns.domain
    exposure_mode = params["exposure_mode"] || socket.assigns.exposure_mode

    if tenant_id == nil or tenant_id == "" do
      {:noreply, put_flash(socket, :error, "Please select a space.")}
    else
      main_template = socket.assigns.selected_template
      env_overrides = build_env_overrides(params)
      ports = parse_port_params(params["ports"])
      volumes = parse_volume_params(params["volumes"])

      main_result =
        if main_template && main_template.id do
          template_updates = %{
            ports: ports,
            volumes: volumes,
            exposure_mode: String.to_existing_atom(exposure_mode)
          }

          Catalog.update_app_template(main_template, template_updates)

          Homelab.Deployments.create_deployment(%{
            tenant_id: String.to_integer(tenant_id),
            app_template_id: main_template.id,
            domain: domain,
            env_overrides: env_overrides
          })
        end

      companion_results =
        Enum.map(socket.assigns.compose_services, fn svc ->
          slug = slugify(svc[:name] || "compose-service")
          image = svc[:image] || ""

          template_attrs = %{
            slug: slug,
            name: svc[:name] || slug,
            version: "latest",
            image: image,
            description: "From compose file",
            source: "compose",
            source_id: image,
            ports: svc[:ports] || [],
            volumes:
              Enum.map(svc[:volumes] || [], fn v ->
                %{
                  "container_path" => v["container_path"] || v["path"] || "/data",
                  "description" => v["description"]
                }
              end),
            default_env:
              svc[:env]
              |> Enum.filter(fn %{"value" => v} -> v != "" end)
              |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end),
            required_env:
              svc[:env]
              |> Enum.filter(fn %{"value" => v} -> v == "" end)
              |> Enum.map(fn %{"key" => k} -> k end),
            depends_on: svc[:depends_on] || [],
            exposure_mode: String.to_existing_atom(exposure_mode)
          }

          template =
            case Catalog.get_app_template_by_slug(slug) do
              {:ok, t} ->
                Catalog.update_app_template(t, template_attrs)
                t

              {:error, :not_found} ->
                case Catalog.create_app_template(template_attrs) do
                  {:ok, t} -> t
                  {:error, _} -> nil
                end
            end

          if template do
            svc_env_overrides =
              (svc[:env] || [])
              |> Enum.reject(fn %{"value" => v} -> v == "" end)
              |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end)

            Homelab.Deployments.deploy_now(%{
              tenant_id: String.to_integer(tenant_id),
              app_template_id: template.id,
              domain: domain,
              env_overrides: svc_env_overrides
            })
          end
        end)

      all_results = [main_result | companion_results]

      success_count =
        Enum.count(all_results, fn
          {:ok, _} -> true
          _ -> false
        end)

      {:noreply,
       socket
       |> put_flash(:info, "#{success_count} service(s) deployed!")
       |> push_navigate(to: ~p"/")}
    end
  end

  # --- Info handlers ---

  @impl true
  def handle_info(:load_curated, socket) do
    entries =
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
      |> deduplicate_entries()

    {:noreply, assign(socket, curated_entries: entries, curated_loading: false)}
  end

  def handle_info({:do_search, query}, socket) do
    results =
      socket.assigns.registries
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

    {:noreply, assign(socket, search_results: results, search_loading: false)}
  end

  def handle_info({:do_companion_search, query}, socket) do
    results =
      socket.assigns.registries
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
      |> Enum.take(8)

    {:noreply, assign(socket, companion_results: results, companion_loading: false)}
  end

  def handle_info({:enrichment_complete, enriched_entry}, socket) do
    template = socket.assigns.selected_template

    if template do
      updated_template = merge_template_with_enrichment(template, enriched_entry)

      env_vars =
        build_env_var_list(
          updated_template.default_env || %{},
          updated_template.required_env || []
        )

      existing_port_internals = MapSet.new(socket.assigns.ports, fn p -> p["internal"] end)

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

      new_ports =
        Enum.reject(enriched_ports, fn p ->
          MapSet.member?(existing_port_internals, p["internal"])
        end)

      merged_ports = socket.assigns.ports ++ new_ports

      existing_vol_paths =
        MapSet.new(socket.assigns.volumes, fn v -> v["container_path"] || v["path"] end)

      enriched_vols =
        Enum.map(enriched_entry.required_volumes, fn v ->
          %{
            "container_path" => v["path"] || v["container_path"],
            "description" => v["description"]
          }
        end)

      new_vols =
        Enum.reject(enriched_vols, fn v ->
          MapSet.member?(existing_vol_paths, v["container_path"])
        end)

      merged_vols = socket.assigns.volumes ++ new_vols

      {:noreply,
       socket
       |> assign(:selected_template, updated_template)
       |> assign(:selected_entry, enriched_entry)
       |> assign(:ports, merged_ports)
       |> assign(:volumes, merged_vols)
       |> assign(:env_vars, env_vars)
       |> assign(:enriching, nil)
       |> recompute_suggestions()}
    else
      {:noreply, assign(socket, :enriching, nil)}
    end
  end

  def handle_info({:enrichment_progress, stage}, socket) do
    {:noreply, assign(socket, :enriching, stage)}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # --- Render ---

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      page_title={@page_title}
      tenants={@tenants}
      current_user={@current_user}
    >
      <div class={[if(@view_mode == :visual, do: "max-w-6xl", else: "max-w-4xl"), "mx-auto"]}>
        <div class="mb-4">
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/catalog"}
              class="text-base-content/30 hover:text-base-content/60 transition-colors"
            >
              <.icon name="hero-arrow-left" class="size-5" />
            </.link>
            <div class="flex-1">
              <h1 class="text-xl font-bold text-base-content">New Deployment</h1>
              <p class="text-xs text-base-content/40 mt-0.5">{step_subtitle(@step)}</p>
            </div>
            <%!-- View mode toggle --%>
            <div
              :if={@step not in ["type", "app"] && @selected_template}
              class="flex items-center p-1 rounded-lg bg-base-200/80"
            >
              <button
                type="button"
                phx-click="toggle_view_mode"
                class={[
                  "flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-colors cursor-pointer",
                  if(@view_mode == :form,
                    do: "bg-base-100 text-base-content shadow-sm",
                    else: "text-base-content/50 hover:text-base-content"
                  )
                ]}
              >
                <.icon name="hero-list-bullet-mini" class="size-3.5" /> Form
              </button>
              <button
                type="button"
                phx-click="toggle_view_mode"
                class={[
                  "flex items-center gap-1.5 px-3 py-1.5 rounded-md text-xs font-medium transition-colors cursor-pointer",
                  if(@view_mode == :visual,
                    do: "bg-base-100 text-base-content shadow-sm",
                    else: "text-base-content/50 hover:text-base-content"
                  )
                ]}
              >
                <.icon name="hero-squares-2x2-mini" class="size-3.5" /> Visual
              </button>
            </div>
          </div>
        </div>

        <%= if @view_mode == :visual && @selected_template do %>
          <.visual_editor_panel
            selected_template={@selected_template}
            ports={@ports}
            volumes={@volumes}
            env_vars={@env_vars}
            domain={@domain}
            exposure_mode={@exposure_mode}
            tenant_id={@tenant_id}
            tenants={@tenants}
            compose_services={@compose_services}
            deploy_type={@deploy_type}
          />
        <% else %>
          <.step_indicator current={@step} deploy_type={@deploy_type} />

          <div class="mt-5">
            <.step_type :if={@step == "type"} />
            <.step_app
              :if={@step == "app"}
              deploy_type={@deploy_type}
              curated_entries={@curated_entries}
              curated_loading={@curated_loading}
              search_query={@search_query}
              search_results={@search_results}
              search_loading={@search_loading}
              compose_yaml={@compose_yaml}
              compose_error={@compose_error}
              compose_services={@compose_services}
              custom_image={@custom_image}
              custom_name={@custom_name}
            />
            <.step_network
              :if={@step == "network"}
              deploy_type={@deploy_type}
              selected_template={@selected_template}
              domain={@domain}
              exposure_mode={@exposure_mode}
              tenant_id={@tenant_id}
              tenants={@tenants}
            />
            <.step_config
              :if={@step == "config"}
              deploy_type={@deploy_type}
              selected_template={@selected_template}
              selected_entry={@selected_entry}
              enriching={@enriching}
              ports={@ports}
              volumes={@volumes}
              env_vars={@env_vars}
              db_suggestions={@db_suggestions}
              infra_suggestions={@infra_suggestions}
              compose_services={@compose_services}
              companion_query={@companion_query}
              companion_results={@companion_results}
              companion_loading={@companion_loading}
            />
            <.step_review
              :if={@step == "review"}
              deploy_type={@deploy_type}
              selected_template={@selected_template}
              ports={@ports}
              volumes={@volumes}
              env_vars={@env_vars}
              domain={@domain}
              exposure_mode={@exposure_mode}
              tenant_id={@tenant_id}
              tenants={@tenants}
              compose_services={@compose_services}
            />
          </div>
        <% end %>
      </div>
    </Layouts.app>
    """
  end

  # ============================================================
  # Step Indicator
  # ============================================================

  defp step_indicator(assigns) do
    steps = [
      %{id: "type", label: "Type", icon: "hero-squares-2x2-mini"},
      %{id: "app", label: "Application", icon: "hero-cube-mini"},
      %{id: "network", label: "Network", icon: "hero-globe-alt-mini"},
      %{id: "config", label: "Configure", icon: "hero-cog-6-tooth-mini"},
      %{id: "review", label: "Review", icon: "hero-check-circle-mini"}
    ]

    current_idx = Enum.find_index(@steps, &(&1 == assigns.current))
    assigns = assign(assigns, :steps_list, steps) |> assign(:current_idx, current_idx)

    ~H"""
    <nav class="flex items-center justify-between">
      <%= for {step, idx} <- Enum.with_index(@steps_list) do %>
        <div class="flex items-center gap-2">
          <div class={[
            "w-8 h-8 rounded-full flex items-center justify-center text-xs font-bold transition-colors",
            cond do
              idx < @current_idx ->
                "bg-primary text-primary-content"

              idx == @current_idx ->
                "bg-primary text-primary-content ring-2 ring-primary/30 ring-offset-2 ring-offset-base-100"

              true ->
                "bg-base-200 text-base-content/30"
            end
          ]}>
            <%= if idx < @current_idx do %>
              <.icon name="hero-check-mini" class="size-4" />
            <% else %>
              {idx + 1}
            <% end %>
          </div>
          <span class={[
            "text-sm font-medium hidden sm:inline",
            if(idx <= @current_idx, do: "text-base-content", else: "text-base-content/30")
          ]}>
            {step.label}
          </span>
        </div>
        <div
          :if={idx < length(@steps_list) - 1}
          class={[
            "flex-1 h-px mx-3",
            if(idx < @current_idx, do: "bg-primary", else: "bg-base-200")
          ]}
        />
      <% end %>
    </nav>
    """
  end

  # ============================================================
  # Step 1: Type Selection
  # ============================================================

  defp step_type(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <button
        type="button"
        phx-click="select_type"
        phx-value-type="container"
        class="group text-left p-4 rounded-lg border border-base-content/5 bg-base-100 hover:border-primary/30 hover:shadow-lg transition-all cursor-pointer"
      >
        <div class="w-12 h-12 rounded-lg bg-primary/10 flex items-center justify-center mb-4">
          <.icon name="hero-cube" class="size-6 text-primary" />
        </div>
        <h3 class="text-lg font-bold text-base-content group-hover:text-primary transition-colors">
          Container
        </h3>
        <p class="text-sm text-base-content/50 mt-2 leading-relaxed">
          Deploy a single Docker container from a catalog app, registry search, or custom image.
        </p>
        <div class="flex items-center gap-1.5 mt-4 text-xs font-medium text-primary/70">
          <span>Most common</span>
          <.icon name="hero-arrow-right-mini" class="size-3.5" />
        </div>
      </button>

      <button
        type="button"
        phx-click="select_type"
        phx-value-type="compose"
        class="group text-left p-4 rounded-lg border border-base-content/5 bg-base-100 hover:border-primary/30 hover:shadow-lg transition-all cursor-pointer"
      >
        <div class="w-12 h-12 rounded-lg bg-secondary/10 flex items-center justify-center mb-4">
          <.icon name="hero-document-text" class="size-6 text-secondary" />
        </div>
        <h3 class="text-lg font-bold text-base-content group-hover:text-secondary transition-colors">
          Compose Project
        </h3>
        <p class="text-sm text-base-content/50 mt-2 leading-relaxed">
          Deploy multiple linked services from a docker-compose.yml file.
        </p>
        <div class="flex items-center gap-1.5 mt-4 text-xs font-medium text-secondary/70">
          <span>Multi-service</span>
          <.icon name="hero-arrow-right-mini" class="size-3.5" />
        </div>
      </button>

      <button
        type="button"
        phx-click="select_type"
        phx-value-type="stack"
        class="group text-left p-4 rounded-lg border border-base-content/5 bg-base-100 hover:border-primary/30 hover:shadow-lg transition-all cursor-pointer"
      >
        <div class="w-12 h-12 rounded-lg bg-info/10 flex items-center justify-center mb-4">
          <.icon name="hero-server-stack" class="size-6 text-info" />
        </div>
        <h3 class="text-lg font-bold text-base-content group-hover:text-info transition-colors">
          Swarm Stack
        </h3>
        <p class="text-sm text-base-content/50 mt-2 leading-relaxed">
          Deploy a replicated service stack across Docker Swarm nodes.
        </p>
        <div class="flex items-center gap-1.5 mt-4 text-xs font-medium text-info/70">
          <span>Scalable</span>
          <.icon name="hero-arrow-right-mini" class="size-3.5" />
        </div>
      </button>
    </div>
    """
  end

  # ============================================================
  # Step 2: App Selection
  # ============================================================

  defp step_app(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        phx-click="back"
        class="flex items-center gap-1.5 text-sm text-base-content/40 hover:text-base-content/70 transition-colors mb-4 cursor-pointer"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" /> Back to type selection
      </button>

      <%= cond do %>
        <% @deploy_type == "compose" -> %>
          <.compose_input
            compose_yaml={@compose_yaml}
            compose_error={@compose_error}
            compose_services={@compose_services}
          />
        <% @deploy_type == "stack" -> %>
          <.compose_input
            compose_yaml={@compose_yaml}
            compose_error={@compose_error}
            compose_services={@compose_services}
          />
        <% true -> %>
          <.container_app_select
            curated_entries={@curated_entries}
            curated_loading={@curated_loading}
            search_query={@search_query}
            search_results={@search_results}
            search_loading={@search_loading}
            custom_image={@custom_image}
            custom_name={@custom_name}
          />
      <% end %>
    </div>
    """
  end

  defp container_app_select(assigns) do
    ~H"""
    <div class="space-y-4">
      <%!-- Search --%>
      <div class="rounded-lg bg-base-100 border border-base-content/5 p-4">
        <h3 class="text-sm font-semibold text-base-content mb-3">Search registries</h3>
        <form phx-submit="search" class="flex gap-3">
          <input
            type="text"
            name="query"
            value={@search_query}
            placeholder="Search for images..."
            class="flex-1 rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
          />
          <button
            type="submit"
            class="px-4 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            Search
          </button>
        </form>

        <div :if={@search_loading} class="py-6 text-center">
          <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/30 mx-auto" />
        </div>

        <div
          :if={!@search_loading && @search_results != []}
          class="mt-4 space-y-2 max-h-64 overflow-y-auto"
        >
          <button
            :for={entry <- @search_results}
            type="button"
            phx-click="select_entry"
            phx-value-entry={encode_entry(entry)}
            class="w-full text-left p-3 rounded-lg hover:bg-base-200/80 transition-colors cursor-pointer"
          >
            <div class="flex items-center justify-between">
              <div>
                <span class="font-medium text-sm text-base-content">{entry.name}</span>
                <span :if={entry.namespace} class="text-xs text-base-content/30 ml-2">
                  {entry.namespace}
                </span>
              </div>
              <.icon name="hero-chevron-right-mini" class="size-4 text-base-content/20" />
            </div>
            <p :if={entry.description} class="text-xs text-base-content/40 mt-0.5 line-clamp-1">
              {entry.description}
            </p>
          </button>
        </div>
      </div>

      <%!-- Custom image --%>
      <div class="rounded-lg bg-base-100 border border-base-content/5 p-4">
        <h3 class="text-sm font-semibold text-base-content mb-3">Custom image</h3>
        <form phx-submit="select_custom" class="space-y-3">
          <div class="flex gap-3">
            <input
              type="text"
              name="image"
              value={@custom_image}
              placeholder="nginx:latest or ghcr.io/owner/repo:tag"
              class="flex-1 rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2.5 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
            />
            <input
              type="text"
              name="name"
              value={@custom_name}
              placeholder="Display name"
              class="w-48 rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
            />
          </div>
          <button
            type="submit"
            class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
          >
            Use this image
          </button>
        </form>
      </div>

      <%!-- Browse catalog --%>
      <div class="rounded-lg bg-base-100 border border-base-content/5 p-4">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-sm font-semibold text-base-content">Browse catalog</h3>
          <button
            :if={@curated_entries == [] && !@curated_loading}
            type="button"
            phx-click="load_curated"
            class="text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
          >
            Load catalog
          </button>
        </div>

        <div :if={@curated_loading} class="py-6 text-center">
          <.icon name="hero-arrow-path" class="size-5 animate-spin text-base-content/30 mx-auto" />
          <p class="text-xs text-base-content/30 mt-2">Loading catalog...</p>
        </div>

        <div
          :if={@curated_entries != []}
          class="grid grid-cols-1 sm:grid-cols-2 gap-2 max-h-80 overflow-y-auto"
        >
          <button
            :for={entry <- @curated_entries}
            type="button"
            phx-click="select_entry"
            phx-value-entry={encode_entry(entry)}
            class="text-left p-3 rounded-lg hover:bg-base-200/80 transition-colors flex items-start gap-3 cursor-pointer"
          >
            <div class="w-8 h-8 rounded-lg bg-primary/10 flex items-center justify-center flex-shrink-0 overflow-hidden">
              <img
                :if={entry.logo_url}
                src={entry.logo_url}
                alt=""
                class="w-full h-full object-contain"
              />
              <.icon :if={!entry.logo_url} name="hero-cube-mini" class="size-4 text-primary" />
            </div>
            <div class="min-w-0">
              <span class="font-medium text-sm text-base-content block truncate">{entry.name}</span>
              <span class="text-xs text-base-content/30 line-clamp-1">{entry.description || ""}</span>
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp compose_input(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-100 border border-base-content/5 p-4">
      <h3 class="text-sm font-semibold text-base-content mb-2">Paste your docker-compose.yml</h3>
      <p class="text-xs text-base-content/40 mb-4">
        We'll parse and extract all services, ports, volumes, and environment variables.
      </p>
      <form phx-submit="parse_compose">
        <textarea
          name="compose_yaml"
          rows="16"
          placeholder="version: '3'\nservices:\n  web:\n    image: nginx:latest\n    ports:\n      - '80:80'"
          class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-3 px-4 placeholder:text-base-content/20 focus:ring-2 focus:ring-primary/50 resize-y"
        >{@compose_yaml}</textarea>

        <div :if={@compose_error} class="mt-3 rounded-lg bg-error/10 border border-error/20 p-3">
          <p class="text-sm text-error flex items-center gap-2">
            <.icon name="hero-exclamation-triangle-mini" class="size-4" />
            {@compose_error}
          </p>
        </div>

        <div
          :if={@compose_services != []}
          class="mt-4 rounded-lg bg-success/5 border border-success/20 p-4"
        >
          <p class="text-sm font-medium text-success flex items-center gap-2">
            <.icon name="hero-check-circle-mini" class="size-4" />
            {length(@compose_services)} service(s) detected
          </p>
          <div class="mt-2 space-y-1">
            <div
              :for={svc <- @compose_services}
              class="flex items-center gap-2 text-xs text-base-content/60"
            >
              <.icon name="hero-cube-mini" class="size-3.5" />
              <span class="font-mono font-medium">{svc[:name]}</span>
              <span class="text-base-content/30">{svc[:image]}</span>
            </div>
          </div>
        </div>

        <div class="flex justify-end mt-4">
          <button
            type="submit"
            class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
          >
            Parse & Continue
          </button>
        </div>
      </form>
    </div>
    """
  end

  # ============================================================
  # Step 3: Configuration
  # ============================================================

  defp step_config(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        phx-click="back"
        class="flex items-center gap-1.5 text-sm text-base-content/40 hover:text-base-content/70 transition-colors mb-3 cursor-pointer"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" /> Back
      </button>

      <%!-- App info banner --%>
      <div
        :if={@selected_template}
        class="rounded-lg bg-base-100 border border-base-content/5 py-2.5 px-3 mb-3 flex items-center gap-3"
      >
        <div class="w-9 h-9 rounded-md bg-primary/10 flex items-center justify-center overflow-hidden flex-shrink-0">
          <img
            :if={@selected_template.logo_url}
            src={@selected_template.logo_url}
            alt=""
            class="w-full h-full object-contain"
          />
          <.icon :if={!@selected_template.logo_url} name="hero-cube" class="size-5 text-primary" />
        </div>
        <div>
          <h3 class="text-sm font-bold text-base-content">{@selected_template.name}</h3>
          <p class="text-[11px] text-base-content/40">{@selected_template.image}</p>
        </div>
        <div
          :if={@enriching}
          class="ml-auto flex items-center gap-1.5 text-[11px] text-base-content/40"
        >
          <.icon name="hero-arrow-path" class="size-3 animate-spin text-primary" />
          <span class="font-medium">Discovering...</span>
        </div>
      </div>

      <div
        :if={@deploy_type == "compose" && @compose_services != []}
        class="rounded-lg bg-base-100 border border-base-content/5 p-3 mb-3"
      >
        <h3 class="text-xs font-semibold text-base-content mb-1.5">Companion Services</h3>
        <div class="space-y-1">
          <div
            :for={svc <- @compose_services}
            class="flex items-center gap-2 py-1.5 px-2 rounded-md bg-base-200/40"
          >
            <.icon name="hero-cube-mini" class="size-3.5 text-primary" />
            <span class="font-mono text-xs font-medium text-base-content">{svc[:name]}</span>
            <span class="text-[10px] text-base-content/30">{svc[:image]}</span>
            <span :if={svc[:depends_on] != []} class="ml-auto text-[10px] text-base-content/30">
              depends on: {Enum.join(svc[:depends_on], ", ")}
            </span>
            <button
              type="button"
              phx-click="remove_companion_service"
              phx-value-name={svc[:name]}
              class="ml-auto text-base-content/20 hover:text-error transition-colors cursor-pointer"
            >
              <.icon name="hero-x-mark-mini" class="size-3.5" />
            </button>
          </div>
        </div>
      </div>

      <div class="grid grid-cols-1 lg:grid-cols-2 gap-3">
        <%!-- Ports --%>
        <div class={[
          "rounded-lg border p-3 transition-colors",
          if(@enriching in ["inspecting"],
            do: "bg-base-100/60 border-base-content/5",
            else: "bg-base-100 border-base-content/5"
          )
        ]}>
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
            <.icon name="hero-signal-mini" class="size-4 text-info" /> Ports
            <.section_enrichment_badge stage={@enriching} affects="inspecting" />
          </h3>
          <%= if @enriching == "inspecting" && @ports == [] do %>
            <.skeleton_rows count={2} />
          <% else %>
            <p class="text-[11px] text-base-content/40 mb-2 leading-snug">
              Ports route through the reverse proxy by default.
              Enable "Publish to host" only for direct access (e.g. database clients).
            </p>
            <div class="space-y-2">
              <div
                :for={{port, idx} <- Enum.with_index(@ports)}
                class="rounded-md bg-base-200/50 p-2.5"
              >
                <div class="flex items-center justify-between mb-1.5">
                  <span
                    :if={port["description"] && port["description"] != ""}
                    class="text-[11px] text-base-content/50"
                  >
                    {port["description"]}
                  </span>
                  <span
                    :if={!port["description"] || port["description"] == ""}
                    class="text-[11px] text-base-content/30 italic"
                  >
                    Port {idx + 1}
                  </span>
                  <button
                    type="button"
                    phx-click="remove_port"
                    phx-value-index={idx}
                    class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                  >
                    <.icon name="hero-x-mark-mini" class="size-3.5" />
                  </button>
                </div>
                <div class="flex items-center gap-2">
                  <div class="flex-1">
                    <label class="block text-[10px] text-base-content/30 mb-0.5">Container</label>
                    <input
                      type="text"
                      name={"ports[#{idx}][internal]"}
                      value={port["internal"] || ""}
                      placeholder="80"
                      class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                    />
                  </div>
                  <div class="w-24">
                    <label class="block text-[10px] text-base-content/30 mb-0.5">Role</label>
                    <select
                      name={"ports[#{idx}][role]"}
                      class="w-full rounded-md bg-base-200 border-0 text-xs text-base-content py-1.5 px-1.5 focus:ring-2 focus:ring-primary/50"
                    >
                      <option
                        :for={{label, value} <- Homelab.Catalog.Enrichers.PortRoles.available_roles()}
                        value={value}
                        selected={value == (port["role"] || "other")}
                      >
                        {label}
                      </option>
                    </select>
                  </div>
                </div>
                <label class="flex items-center gap-2 mt-1.5 cursor-pointer select-none group">
                  <input
                    type="checkbox"
                    name={"ports[#{idx}][published]"}
                    value="true"
                    checked={port["published"] == true || port["published"] == "true"}
                    class="rounded border-base-content/20 text-primary focus:ring-primary/50 size-3.5"
                  />
                  <span class="text-[10px] text-base-content/40 group-hover:text-base-content/60 transition-colors">
                    Publish to host on port
                  </span>
                  <input
                    :if={port["published"] == true || port["published"] == "true"}
                    type="text"
                    name={"ports[#{idx}][external]"}
                    value={port["external"] || port["internal"]}
                    placeholder={port["internal"]}
                    class="w-16 rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1 px-2 focus:ring-2 focus:ring-primary/50"
                  />
                  <input
                    :if={!(port["published"] == true || port["published"] == "true")}
                    type="hidden"
                    name={"ports[#{idx}][external]"}
                    value={port["external"] || port["internal"]}
                  />
                </label>
              </div>
              <button
                type="button"
                phx-click="add_port"
                class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
              >
                <.icon name="hero-plus-mini" class="size-3.5" /> Add port
              </button>
            </div>
          <% end %>
        </div>

        <%!-- Volumes --%>
        <div class={[
          "rounded-lg border p-3 transition-colors",
          if(@enriching in ["inspecting"],
            do: "bg-base-100/60 border-base-content/5",
            else: "bg-base-100 border-base-content/5"
          )
        ]}>
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
            <.icon name="hero-circle-stack-mini" class="size-4 text-secondary" /> Volumes
            <.section_enrichment_badge stage={@enriching} affects="inspecting" />
          </h3>
          <%= if @enriching == "inspecting" && @volumes == [] do %>
            <.skeleton_rows count={1} />
          <% else %>
            <div class="space-y-2">
              <div
                :for={{vol, idx} <- Enum.with_index(@volumes)}
                class="rounded-md bg-base-200/50 p-2.5"
              >
                <div class="flex items-center justify-between mb-1.5">
                  <span
                    :if={vol["description"] && vol["description"] != ""}
                    class="text-[11px] text-base-content/50"
                  >
                    {vol["description"]}
                  </span>
                  <span
                    :if={!vol["description"] || vol["description"] == ""}
                    class="text-[11px] text-base-content/30 italic"
                  >
                    Volume {idx + 1}
                  </span>
                  <button
                    type="button"
                    phx-click="remove_volume"
                    phx-value-index={idx}
                    class="text-base-content/25 hover:text-error transition-colors cursor-pointer"
                  >
                    <.icon name="hero-x-mark-mini" class="size-3.5" />
                  </button>
                </div>
                <div>
                  <label class="block text-[10px] text-base-content/30 mb-0.5">Container path</label>
                  <input
                    type="text"
                    name={"volumes[#{idx}][container_path]"}
                    value={vol["path"] || vol["container_path"] || ""}
                    placeholder="/data"
                    class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                  />
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
          <% end %>
        </div>
      </div>

      <%!-- Environment Variables --%>
      <div class={[
        "rounded-lg border p-3 mt-4 transition-colors",
        if(@enriching,
          do: "bg-base-100/60 border-base-content/5",
          else: "bg-base-100 border-base-content/5"
        )
      ]}>
        <div class="flex items-center gap-2 mb-2">
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2">
            <.icon name="hero-key-mini" class="size-4 text-warning" /> Environment Variables
            <.section_enrichment_badge stage={@enriching} affects="scanning" />
          </h3>
          <span
            :if={@enriching && @env_vars != []}
            class="flex items-center gap-1.5 text-[10px] text-base-content/30 ml-auto"
          >
            <.icon name="hero-arrow-path" class="size-3 animate-spin" /> Discovering...
          </span>
          <span :if={!@enriching} class="text-[10px] font-normal text-base-content/30 ml-auto">
            {length(@env_vars)} variables
          </span>
        </div>

        <%= if @enriching && @env_vars == [] do %>
          <.skeleton_rows count={3} />
          <p class="text-[10px] text-base-content/30 text-center mt-1">Scanning...</p>
        <% else %>
          <div :if={@env_vars == [] && !@enriching} class="py-3 text-center">
            <p class="text-xs text-base-content/30">No environment variables configured yet.</p>
          </div>

          <div :if={@env_vars != []}>
            <div class="grid grid-cols-[1fr_2fr_auto] gap-x-2 text-[10px] text-base-content/30 px-2 mb-1">
              <span>Key</span>
              <span>Value</span>
              <span class="w-5"></span>
            </div>
            <div class="space-y-1">
              <div
                :for={{env, idx} <- Enum.with_index(@env_vars)}
                class="grid grid-cols-[1fr_2fr_auto] gap-x-2 items-center"
              >
                <input
                  type="text"
                  name={"env[#{idx}][key]"}
                  value={env["key"]}
                  placeholder="VARIABLE_NAME"
                  class="w-full rounded-md bg-base-200/60 border-0 text-[11px] font-mono font-medium text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                />
                <input
                  type={if(sensitive_key?(env["key"]), do: "password", else: "text")}
                  name={"env[#{idx}][value]"}
                  value={env["value"]}
                  placeholder={if(env["required"], do: "Required", else: "")}
                  class={[
                    "w-full rounded-md bg-base-200/60 border-0 text-[11px] font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50",
                    if(env["required"] && (env["value"] == nil || env["value"] == ""),
                      do: "ring-1 ring-warning/30",
                      else: ""
                    )
                  ]}
                />
                <button
                  type="button"
                  phx-click="remove_env_var"
                  phx-value-index={idx}
                  class="text-base-content/20 hover:text-error transition-colors cursor-pointer w-5 flex items-center justify-center"
                >
                  <.icon name="hero-x-mark-mini" class="size-3.5" />
                </button>
              </div>
            </div>
          </div>

          <button
            :if={!@enriching}
            type="button"
            phx-click="add_env_var"
            class="flex items-center gap-1 text-[11px] font-medium text-primary hover:text-primary/80 transition-colors mt-2 cursor-pointer"
          >
            <.icon name="hero-plus-mini" class="size-3" /> Add variable
          </button>
        <% end %>
      </div>

      <%!-- Database dependency suggestions --%>
      <div :if={@db_suggestions != [] && !@enriching} class="mt-4 space-y-2">
        <.db_suggestion_card :for={suggestion <- @db_suggestions} suggestion={suggestion} />
      </div>

      <%!-- Infrastructure suggestions --%>
      <div :if={@infra_suggestions != [] && !@enriching} class="mt-4">
        <div class="rounded-lg border border-info/20 bg-info/5 p-3">
          <div class="flex items-center justify-between mb-2">
            <div class="flex items-center gap-2">
              <.icon name="hero-light-bulb" class="size-4 text-info" />
              <h4 class="text-sm font-semibold text-base-content">Smart auto-fill</h4>
              <span class="text-[10px] font-medium text-info/60 px-1.5 py-0.5 rounded-full bg-info/10">
                {length(@infra_suggestions)} detected
              </span>
            </div>
            <button
              :if={length(@infra_suggestions) > 1}
              type="button"
              phx-click="apply_all_infra"
              class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-info/10 text-info text-[10px] font-medium hover:bg-info/20 transition-colors cursor-pointer"
            >
              <.icon name="hero-bolt-mini" class="size-3" /> Apply all
            </button>
          </div>
          <div class="space-y-1.5">
            <.infra_suggestion_row :for={suggestion <- @infra_suggestions} suggestion={suggestion} />
          </div>
        </div>
      </div>

      <%!-- Add companion service --%>
      <div :if={!@enriching} class="mt-4">
        <div class="rounded-lg border border-base-content/5 bg-base-100 p-3">
          <div class="flex items-center gap-2 mb-2">
            <.icon name="hero-squares-plus" class="size-4 text-primary" />
            <h4 class="text-sm font-semibold text-base-content">Add companion service</h4>
            <span class="text-[10px] text-base-content/30">
              Search the catalog or enter a custom image
            </span>
          </div>
          <div class="flex gap-2">
            <div class="flex-1 relative">
              <input
                type="text"
                phx-keyup="companion_search"
                phx-debounce="300"
                value={@companion_query}
                placeholder="Search for redis, postgres, nginx..."
                class="w-full rounded-md bg-base-200 border-0 text-xs text-base-content py-2 px-3 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
              />
              <.icon
                :if={@companion_loading}
                name="hero-arrow-path"
                class="size-3.5 animate-spin text-primary absolute right-2.5 top-2"
              />
            </div>
            <button
              :if={@companion_query != "" && @companion_results == []}
              type="button"
              phx-click="add_companion_custom"
              phx-value-image={@companion_query}
              class="px-3 py-2 rounded-md bg-primary text-primary-content text-[11px] font-medium hover:bg-primary/90 transition-colors cursor-pointer whitespace-nowrap"
            >
              <.icon name="hero-plus-mini" class="size-3 inline" /> Add as image
            </button>
          </div>
          <div
            :if={@companion_results != []}
            class="mt-2 space-y-0.5 max-h-48 overflow-y-auto"
          >
            <button
              :for={entry <- @companion_results}
              type="button"
              phx-click="add_companion_entry"
              phx-value-entry={encode_entry(entry)}
              class="w-full text-left flex items-center gap-2.5 py-1.5 px-2 rounded-md hover:bg-base-200/80 transition-colors cursor-pointer"
            >
              <div class="w-6 h-6 rounded-md bg-primary/10 flex items-center justify-center flex-shrink-0 overflow-hidden">
                <img
                  :if={entry.logo_url}
                  src={entry.logo_url}
                  alt=""
                  class="w-full h-full object-contain"
                />
                <.icon :if={!entry.logo_url} name="hero-cube-mini" class="size-3.5 text-primary" />
              </div>
              <div class="flex-1 min-w-0">
                <span class="text-[11px] font-medium text-base-content">{entry.name}</span>
                <span class="text-[10px] text-base-content/30 ml-1.5 truncate">{entry.full_ref}</span>
              </div>
              <.icon name="hero-plus-mini" class="size-3.5 text-primary flex-shrink-0" />
            </button>
          </div>
          <div
            :if={@companion_query != "" && !@companion_loading && @companion_results == []}
            class="mt-2 text-center"
          >
            <p class="text-[11px] text-base-content/30">
              No catalog results. Use "Add as image" to add
              <code class="font-mono text-[10px] bg-base-200 px-1 rounded">{@companion_query}</code>
              directly.
            </p>
          </div>
        </div>
      </div>

      <%!-- Next button --%>
      <div class="flex justify-end mt-4">
        <button
          type="button"
          phx-click="go_step"
          phx-value-step="review"
          class="px-5 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors cursor-pointer"
        >
          Next: Review <.icon name="hero-arrow-right-mini" class="size-4 inline ml-1" />
        </button>
      </div>
    </div>
    """
  end

  defp db_suggestion_card(assigns) do
    has_missing? = assigns.suggestion.missing_keys != []
    resolved? = Map.get(assigns.suggestion, :resolved?, false)
    assigns = assign(assigns, :has_missing?, has_missing?) |> assign(:resolved?, resolved?)

    ~H"""
    <div class={[
      "rounded-lg border p-3 transition-colors",
      if(@resolved?, do: "border-success/20 bg-success/5", else: "border-warning/20 bg-warning/5")
    ]}>
      <div class="flex items-center gap-2.5">
        <div class={[
          "w-8 h-8 rounded-md flex items-center justify-center flex-shrink-0",
          if(@resolved?, do: "bg-success/10", else: "bg-warning/10")
        ]}>
          <%= if @resolved? do %>
            <.icon name="hero-check-circle" class="size-4 text-success" />
          <% else %>
            <.icon name={@suggestion.icon} class="size-4 text-warning" />
          <% end %>
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <h4 class="text-xs font-semibold text-base-content">
              <%= if @resolved? do %>
                {@suggestion.label} companion added
              <% else %>
                {@suggestion.label} dependency detected
              <% end %>
            </h4>
            <%= if @resolved? do %>
              <span class="inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded-full bg-success/10 text-success text-[10px] font-medium">
                <.icon name="hero-check-mini" class="size-2.5" /> Configured
              </span>
            <% else %>
              <span
                :if={@has_missing?}
                class="inline-flex items-center gap-0.5 px-1.5 py-0.5 rounded-full bg-warning/10 text-warning text-[10px] font-medium"
              >
                <.icon name="hero-exclamation-triangle-mini" class="size-2.5" />
                {length(@suggestion.missing_keys)} unconfigured
              </span>
            <% end %>
          </div>

          <%= if @resolved? do %>
            <p class="text-[11px] text-success/70 mt-0.5">
              Companion {@suggestion.label} will deploy with shared credentials.
            </p>
          <% else %>
            <p class="text-[11px] text-base-content/40 mt-0.5">
              References
              <span :for={{key, idx} <- Enum.with_index(@suggestion.matched_keys)}>
                <code class="px-1 rounded bg-base-200 text-[10px] font-mono">{key}</code>{if idx <
                                                                                               length(
                                                                                                 @suggestion.matched_keys
                                                                                               ) -
                                                                                                 1,
                                                                                             do: " "}
              </span>
            </p>
          <% end %>
        </div>

        <%= unless @resolved? do %>
          <div class="flex items-center gap-1.5 flex-shrink-0">
            <button
              type="button"
              phx-click="add_companion_db"
              phx-value-db-type={@suggestion.db_type}
              class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-primary text-primary-content text-[11px] font-medium hover:bg-primary/90 transition-colors cursor-pointer"
            >
              <.icon name="hero-plus-mini" class="size-3" /> Add {@suggestion.label}
            </button>
            <button
              :if={@has_missing?}
              type="button"
              phx-click="wire_db_secrets"
              phx-value-db-type={@suggestion.db_type}
              class="inline-flex items-center gap-1 px-2.5 py-1.5 rounded-md bg-base-200 text-base-content text-[11px] font-medium hover:bg-base-300 transition-colors cursor-pointer"
            >
              <.icon name="hero-key-mini" class="size-3" /> Secrets only
            </button>
          </div>
        <% end %>
      </div>
    </div>
    """
  end

  defp infra_suggestion_row(assigns) do
    fill_count = map_size(assigns.suggestion.fills)
    assigns = assign(assigns, :fill_count, fill_count)

    ~H"""
    <div class="flex items-center gap-2.5 rounded-md bg-base-100/80 py-2 px-2.5">
      <div class={"w-6 h-6 rounded-md bg-#{@suggestion.color}/10 flex items-center justify-center flex-shrink-0"}>
        <.icon name={@suggestion.icon} class={"size-3.5 text-#{@suggestion.color}"} />
      </div>
      <div class="flex-1 min-w-0">
        <div class="flex items-center gap-1.5">
          <span class="text-[11px] font-semibold text-base-content">{@suggestion.label}</span>
          <span class="text-[10px] text-base-content/30 truncate">{@suggestion.description}</span>
        </div>
        <div class="flex flex-wrap gap-0.5 mt-0.5">
          <span
            :for={key <- @suggestion.matched_keys}
            class="text-[9px] font-mono px-1 py-0 rounded bg-base-200 text-base-content/50"
          >
            {key}
          </span>
        </div>
      </div>
      <div class="flex items-center gap-1.5 flex-shrink-0">
        <span class="text-[10px] text-base-content/30">{@fill_count}</span>
        <button
          type="button"
          phx-click="apply_infra"
          phx-value-infra-id={@suggestion.id}
          class="inline-flex items-center gap-1 px-2 py-1 rounded-md bg-info/10 text-info text-[10px] font-medium hover:bg-info/20 transition-colors cursor-pointer"
        >
          <.icon name="hero-bolt-mini" class="size-2.5" /> Apply
        </button>
      </div>
    </div>
    """
  end

  # ============================================================
  # Step 4: Networking
  # ============================================================

  defp step_network(assigns) do
    ~H"""
    <div>
      <button
        type="button"
        phx-click="back"
        class="flex items-center gap-1.5 text-sm text-base-content/40 hover:text-base-content/70 transition-colors mb-3 cursor-pointer"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" /> Back
      </button>

      <.form
        for={to_form(%{"tenant_id" => @tenant_id || "", "domain" => @domain || ""}, as: :network)}
        id="network-form"
        phx-change="update_network"
        class="grid grid-cols-1 lg:grid-cols-2 gap-3"
      >
        <%!-- Space selection --%>
        <div class="rounded-lg bg-base-100 border border-base-content/5 p-3">
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
            <.icon name="hero-folder-mini" class="size-4 text-primary" /> Space
          </h3>
          <select
            id="tenant-select"
            name="network[tenant_id]"
            class="w-full rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >
            <option value="" disabled selected={@tenant_id == nil}>Select a space...</option>
            <option
              :for={tenant <- @tenants}
              value={tenant.id}
              selected={to_string(tenant.id) == to_string(@tenant_id)}
            >
              {tenant.name} ({tenant.slug})
            </option>
          </select>
        </div>

        <%!-- Domain --%>
        <div class="rounded-lg bg-base-100 border border-base-content/5 p-3">
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
            <.icon name="hero-globe-alt-mini" class="size-4 text-info" /> Domain
            <span class="text-[10px] font-normal text-base-content/30">optional</span>
          </h3>
          <input
            type="text"
            name="network[domain]"
            value={@domain}
            phx-debounce="300"
            placeholder={
              if(@selected_template,
                do: "#{@selected_template.slug}.yourdomain.com",
                else: "app.yourdomain.com"
              )
            }
            class="w-full rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 placeholder:text-base-content/25 focus:ring-2 focus:ring-primary/50"
          />
          <p class="text-[10px] text-base-content/30 mt-1.5">
            Enables reverse proxy routing on ports 80/443.
          </p>
        </div>
      </.form>

      <%!-- Exposure mode --%>
      <div class="rounded-lg bg-base-100 border border-base-content/5 p-3 mt-4">
        <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
          <.icon name="hero-shield-check-mini" class="size-4 text-success" /> Access & Exposure
        </h3>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-2">
          <.exposure_option
            mode="public"
            current={@exposure_mode}
            icon="hero-globe-alt"
            title="Public"
            desc="Anyone via domain"
            color="warning"
          />
          <.exposure_option
            mode="sso_protected"
            current={@exposure_mode}
            icon="hero-shield-check"
            title="SSO"
            desc="Requires OIDC auth"
            color="success"
          />
          <.exposure_option
            mode="private"
            current={@exposure_mode}
            icon="hero-lock-closed"
            title="Private"
            desc="LAN only (RFC 1918)"
            color="base-content"
          />
          <.exposure_option
            mode="service"
            current={@exposure_mode}
            icon="hero-server-stack"
            title="Service"
            desc="Internal only, no host ports"
            color="info"
          />
        </div>

        <div
          :if={@exposure_mode == "service"}
          class="mt-2.5 rounded-md bg-info/5 border border-info/20 py-2 px-3"
        >
          <div class="flex items-start gap-2">
            <.icon
              name="hero-information-circle-mini"
              class="size-3.5 text-info/70 mt-0.5 flex-shrink-0"
            />
            <p class="text-[11px] text-base-content/40 leading-relaxed">
              No host ports published. Accessible only through Docker network and Traefik reverse proxy.
            </p>
          </div>
        </div>
      </div>

      <%!-- Next button --%>
      <div class="flex justify-end mt-4">
        <button
          type="button"
          phx-click="go_step"
          phx-value-step="config"
          class="px-5 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors cursor-pointer"
        >
          Next: Configure <.icon name="hero-arrow-right-mini" class="size-4 inline ml-1" />
        </button>
      </div>
    </div>
    """
  end

  defp exposure_option(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="update_network"
      phx-value-exposure_mode={@mode}
      class={[
        "text-left py-2.5 px-3 rounded-md border-2 transition-all cursor-pointer",
        if(@current == @mode,
          do: "border-primary bg-primary/5",
          else: "border-base-content/5 bg-base-200/30 hover:border-base-content/15"
        )
      ]}
    >
      <.icon name={@icon} class={["size-4 mb-1", "text-#{@color}"]} />
      <h4 class="text-xs font-semibold text-base-content">{@title}</h4>
      <p class="text-[10px] text-base-content/40 mt-0.5 leading-snug">{@desc}</p>
    </button>
    """
  end

  # ============================================================
  # Step 5: Review & Deploy
  # ============================================================

  defp step_review(assigns) do
    template = assigns.selected_template

    tenant =
      Enum.find(assigns.tenants, fn t -> to_string(t.id) == to_string(assigns.tenant_id) end)

    topo = HomelabWeb.Topology.from_wizard_state(assigns)

    assigns =
      assign(assigns, :tenant, tenant) |> assign(:template, template) |> assign(:topo, topo)

    ~H"""
    <div>
      <button
        type="button"
        phx-click="back"
        class="flex items-center gap-1.5 text-sm text-base-content/40 hover:text-base-content/70 transition-colors mb-3 cursor-pointer"
      >
        <.icon name="hero-arrow-left-mini" class="size-4" /> Back
      </button>

      <.form
        for={to_form(%{})}
        id="deploy-review-form"
        phx-submit={if(@deploy_type == "compose", do: "deploy_compose", else: "deploy")}
        class="space-y-3"
      >
        <input type="hidden" name="tenant_id" value={@tenant_id || ""} />
        <input type="hidden" name="domain" value={@domain} />
        <input type="hidden" name="exposure_mode" value={@exposure_mode} />

        <%!-- Infrastructure topology preview --%>
        <div :if={@topo.nodes != []} class="space-y-1.5">
          <h3 class="text-[10px] font-semibold text-base-content/40 uppercase tracking-wider flex items-center gap-1.5">
            <.icon name="hero-squares-2x2" class="size-3.5 text-base-content/30" /> Topology
          </h3>
          <.topology nodes={@topo.nodes} edges={@topo.edges} />
        </div>

        <%!-- Summary cards --%>
        <div class="grid grid-cols-2 lg:grid-cols-4 gap-2">
          <div class="rounded-md bg-base-100 border border-base-content/5 py-2 px-3">
            <p class="text-[9px] font-semibold uppercase tracking-wider text-base-content/30">
              Application
            </p>
            <p class="text-xs font-bold text-base-content truncate mt-0.5">
              <%= if @template do %>
                {@template.name}
              <% else %>
                {length(@compose_services)} services
              <% end %>
            </p>
          </div>
          <div class="rounded-md bg-base-100 border border-base-content/5 py-2 px-3">
            <p class="text-[9px] font-semibold uppercase tracking-wider text-base-content/30">
              Space
            </p>
            <p class="text-xs font-bold text-base-content truncate mt-0.5">
              {if(@tenant, do: @tenant.name, else: "Not selected")}
            </p>
          </div>
          <div class="rounded-md bg-base-100 border border-base-content/5 py-2 px-3">
            <p class="text-[9px] font-semibold uppercase tracking-wider text-base-content/30">
              Domain
            </p>
            <p class="text-xs font-bold text-base-content truncate mt-0.5">
              {if(@domain != "", do: @domain, else: "None")}
            </p>
          </div>
          <div class="rounded-md bg-base-100 border border-base-content/5 py-2 px-3">
            <p class="text-[9px] font-semibold uppercase tracking-wider text-base-content/30">
              Exposure
            </p>
            <p class="text-xs font-bold text-base-content mt-0.5">
              {format_exposure(@exposure_mode)}
            </p>
          </div>
        </div>

        <%!-- Detailed config --%>
        <div class="rounded-lg bg-base-100 border border-base-content/5 p-3">
          <h3 class="text-xs font-semibold text-base-content mb-2">Configuration summary</h3>

          <%!-- Ports --%>
          <div class="mb-3">
            <p class="text-[11px] font-semibold text-base-content/40 mb-1">
              {length(@ports)} Port(s)
            </p>
            <div :if={@ports != []} class="flex flex-wrap gap-1.5">
              <span
                :for={{port, idx} <- Enum.with_index(@ports)}
                class={[
                  "inline-flex items-center gap-1 text-[11px] font-mono rounded px-1.5 py-0.5",
                  if(port["published"] == true || port["published"] == "true",
                    do: "bg-warning/10 ring-1 ring-warning/20",
                    else: "bg-base-200"
                  )
                ]}
              >
                <input type="hidden" name={"ports[#{idx}][internal]"} value={port["internal"]} />
                <input
                  type="hidden"
                  name={"ports[#{idx}][external]"}
                  value={port["external"] || port["internal"]}
                />
                <input type="hidden" name={"ports[#{idx}][role]"} value={port["role"] || "other"} />
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
                <input
                  type="hidden"
                  name={"ports[#{idx}][published]"}
                  value={to_string(port["published"] || false)}
                />
                <%= if port["published"] == true || port["published"] == "true" do %>
                  <.icon name="hero-arrow-up-on-square-mini" class="size-2.5 text-warning" />
                  {port["external"] || port["internal"]}:{port["internal"]}
                <% else %>
                  {port["internal"]}
                <% end %>
                <span :if={port["role"] == "web"} class="text-[9px] text-info font-sans">web</span>
              </span>
            </div>
            <p :if={@ports == []} class="text-[11px] text-base-content/30 italic">
              No ports configured
            </p>
          </div>

          <%!-- Volumes --%>
          <div class="mb-3">
            <p class="text-[11px] font-semibold text-base-content/40 mb-1">
              {length(@volumes)} Volume(s)
            </p>
            <div :if={@volumes != []} class="flex flex-wrap gap-1.5">
              <span
                :for={{vol, idx} <- Enum.with_index(@volumes)}
                class="inline-flex items-center gap-1 text-[11px] font-mono bg-base-200 rounded px-1.5 py-0.5"
              >
                <input
                  type="hidden"
                  name={"volumes[#{idx}][container_path]"}
                  value={vol["path"] || vol["container_path"] || ""}
                />
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
                <.icon name="hero-circle-stack-mini" class="size-2.5 text-secondary" />
                {vol["path"] || vol["container_path"]}
              </span>
            </div>
            <p :if={@volumes == []} class="text-[11px] text-base-content/30 italic">
              No volumes configured
            </p>
          </div>

          <%!-- Env vars --%>
          <div>
            <p class="text-[11px] font-semibold text-base-content/40 mb-1">
              {length(@env_vars)} Environment Variable(s)
            </p>
            <div :if={@env_vars != []} class="space-y-0.5">
              <div
                :for={{env, idx} <- Enum.with_index(@env_vars)}
                class="flex items-center gap-1.5 text-[11px]"
              >
                <input type="hidden" name={"env_overrides[#{env["key"]}]"} value={env["value"] || ""} />
                <span class="font-mono font-medium text-base-content/60">{env["key"]}</span>
                <span class="text-base-content/20">=</span>
                <span class={[
                  "font-mono truncate max-w-xs",
                  if(sensitive_key?(env["key"]),
                    do: "text-base-content/20",
                    else: "text-base-content/50"
                  )
                ]}>
                  {if(sensitive_key?(env["key"]), do: "••••••", else: env["value"] || "")}
                </span>
              </div>
            </div>
            <p :if={@env_vars == []} class="text-[11px] text-base-content/30 italic">
              No environment variables
            </p>
          </div>
        </div>

        <%!-- Warning for service mode --%>
        <div
          :if={@exposure_mode == "service"}
          class="rounded-md bg-info/5 border border-info/20 py-2 px-3 flex items-start gap-2"
        >
          <.icon name="hero-server-stack-mini" class="size-4 text-info mt-0.5 flex-shrink-0" />
          <p class="text-[11px] text-base-content/40 leading-relaxed">
            <span class="font-medium text-base-content/60">Service mode:</span>
            No host ports published. Traffic routed exclusively through Traefik.
          </p>
        </div>

        <%!-- Deploy button --%>
        <div class="flex items-center justify-end gap-3">
          <.link
            navigate={~p"/catalog"}
            class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/50 hover:text-base-content/70 hover:bg-base-200 transition-colors"
          >
            Cancel
          </.link>
          <button
            type="submit"
            class="px-6 py-2 rounded-lg bg-primary text-primary-content text-sm font-bold hover:bg-primary/90 transition-colors shadow-lg shadow-primary/20 cursor-pointer"
          >
            <.icon name="hero-rocket-launch-mini" class="size-4 inline mr-1" /> Deploy
          </button>
        </div>
      </.form>
    </div>
    """
  end

  # ============================================================
  # Visual Editor Panel
  # ============================================================

  defp visual_editor_panel(assigns) do
    alias HomelabWeb.Topology
    topo = Topology.from_wizard_state(assigns)

    tenant =
      Enum.find(assigns.tenants, fn t -> to_string(t.id) == to_string(assigns.tenant_id) end)

    assigns = assign(assigns, topo: topo, tenant: tenant)

    ~H"""
    <div class="space-y-4">
      <%!-- Topology diagram --%>
      <.topology_editor
        nodes={@topo.nodes}
        edges={@topo.edges}
        on_change="topology_change"
        on_add="topology_add"
        on_remove="topology_remove"
      />

      <%!-- Quick config panels below the topology --%>
      <div class="grid grid-cols-1 lg:grid-cols-3 gap-4">
        <div class="rounded-lg bg-base-100 border border-base-content/[0.06] p-4">
          <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Space
          </h4>
          <p class="text-sm font-medium text-base-content">
            {if(@tenant, do: @tenant.name, else: "Not selected")}
          </p>
          <p class="text-[11px] text-base-content/30 mt-1">
            Switch to Form mode to change space
          </p>
        </div>
        <div class="rounded-lg bg-base-100 border border-base-content/[0.06] p-4">
          <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Configuration
          </h4>
          <div class="space-y-1 text-xs text-base-content/60">
            <div class="flex justify-between">
              <span>Ports</span>
              <span class="font-medium text-base-content">{length(@ports)}</span>
            </div>
            <div class="flex justify-between">
              <span>Volumes</span>
              <span class="font-medium text-base-content">{length(@volumes)}</span>
            </div>
            <div class="flex justify-between">
              <span>Env vars</span>
              <span class="font-medium text-base-content">{length(@env_vars)}</span>
            </div>
          </div>
        </div>
        <div class="rounded-lg bg-base-100 border border-base-content/[0.06] p-4">
          <h4 class="text-xs font-semibold text-base-content/50 uppercase tracking-wider mb-3">
            Deploy
          </h4>
          <.form
            for={to_form(%{})}
            id="visual-deploy-form"
            phx-submit={if(@deploy_type == "compose", do: "deploy_compose", else: "deploy")}
          >
            <input type="hidden" name="tenant_id" value={@tenant_id || ""} />
            <input type="hidden" name="domain" value={@domain} />
            <input type="hidden" name="exposure_mode" value={@exposure_mode} />
            <input
              :for={{port, idx} <- Enum.with_index(@ports)}
              type="hidden"
              name={"ports[#{idx}][internal]"}
              value={port["internal"]}
            />
            <input
              :for={{port, idx} <- Enum.with_index(@ports)}
              type="hidden"
              name={"ports[#{idx}][external]"}
              value={port["external"] || port["internal"]}
            />
            <input
              :for={{port, idx} <- Enum.with_index(@ports)}
              type="hidden"
              name={"ports[#{idx}][role]"}
              value={port["role"] || "other"}
            />
            <input
              :for={{port, idx} <- Enum.with_index(@ports)}
              type="hidden"
              name={"ports[#{idx}][published]"}
              value={to_string(port["published"] || false)}
            />
            <input
              :for={{vol, idx} <- Enum.with_index(@volumes)}
              type="hidden"
              name={"volumes[#{idx}][container_path]"}
              value={vol["path"] || vol["container_path"] || ""}
            />
            <input
              :for={env <- @env_vars}
              type="hidden"
              name={"env_overrides[#{env["key"]}]"}
              value={env["value"] || ""}
            />
            <button
              type="submit"
              class="w-full px-6 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-bold hover:bg-primary/90 transition-colors shadow-lg shadow-primary/20 cursor-pointer flex items-center justify-center gap-2"
            >
              <.icon name="hero-rocket-launch-mini" class="size-4" /> Deploy
            </button>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================
  # Helpers
  # ============================================================

  defp step_subtitle("type"), do: "Choose your deployment type"
  defp step_subtitle("app"), do: "Select an application to deploy"
  defp step_subtitle("config"), do: "Configure ports, volumes, and environment"
  defp step_subtitle("network"), do: "Set up domain, access, and networking"
  defp step_subtitle("review"), do: "Review and deploy"
  defp step_subtitle(_), do: ""

  defp prev_step("app"), do: "type"
  defp prev_step("network"), do: "app"
  defp prev_step("config"), do: "network"
  defp prev_step("review"), do: "config"
  defp prev_step(_), do: "type"

  defp build_step_params(socket, step) do
    params = %{"step" => step}

    params =
      if socket.assigns.deploy_type,
        do: Map.put(params, "type", socket.assigns.deploy_type),
        else: params

    params =
      if socket.assigns.selected_template && socket.assigns.selected_template.id,
        do: Map.put(params, "template_id", socket.assigns.selected_template.id),
        else: params

    params
  end

  defp build_env_var_list(default_env, required_env) do
    required_items =
      Enum.map(required_env, fn key ->
        %{"key" => key, "value" => Map.get(default_env, key, ""), "required" => true}
      end)

    default_items =
      default_env
      |> Enum.reject(fn {key, _} -> key in required_env end)
      |> Enum.map(fn {key, value} ->
        %{"key" => key, "value" => value, "required" => false}
      end)

    required_items ++ default_items
  end

  defp build_env_overrides(params) do
    env_overrides = params["env_overrides"] || %{}

    env_from_indexed = params["env"] || %{}

    indexed_env =
      env_from_indexed
      |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
      |> Enum.reject(fn {_, e} -> (e["key"] || "") == "" end)
      |> Map.new(fn {_, e} -> {e["key"], e["value"] || ""} end)

    Map.merge(indexed_env, env_overrides)
    |> Enum.reject(fn {_k, v} -> v == "" end)
    |> Map.new()
  end

  defp merge_template_with_enrichment(template, enriched_entry) do
    existing_default_env = template.default_env || %{}
    existing_required_env = template.required_env || []

    merged_default_env = Map.merge(enriched_entry.default_env, existing_default_env)

    all_known_keys = MapSet.new(Map.keys(existing_default_env) ++ existing_required_env)
    new_required = Enum.reject(enriched_entry.required_env, &MapSet.member?(all_known_keys, &1))
    merged_required_env = existing_required_env ++ new_required

    existing_ports = template.ports || []

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

    existing_port_internals = MapSet.new(existing_ports, fn p -> p["internal"] end)

    new_ports =
      Enum.reject(enriched_ports, fn p ->
        MapSet.member?(existing_port_internals, p["internal"])
      end)

    existing_vols = template.volumes || []

    enriched_vols =
      Enum.map(enriched_entry.required_volumes, fn v ->
        %{"container_path" => v["path"] || v["container_path"], "description" => v["description"]}
      end)

    existing_vol_paths = MapSet.new(existing_vols, fn v -> v["container_path"] end)

    new_vols =
      Enum.reject(enriched_vols, fn v ->
        MapSet.member?(existing_vol_paths, v["container_path"])
      end)

    struct(template, %{
      default_env: merged_default_env,
      required_env: merged_required_env,
      ports: existing_ports ++ new_ports,
      volumes: existing_vols ++ new_vols
    })
  end

  attr :stage, :string, required: true
  attr :affects, :string, required: true
  defp section_enrichment_badge(%{stage: nil} = assigns), do: ~H""

  defp section_enrichment_badge(assigns) do
    active? = stage_affects?(assigns.stage, assigns.affects)
    done? = stage_past?(assigns.stage, assigns.affects)
    assigns = assign(assigns, active?: active?, done?: done?)

    ~H"""
    <span
      :if={@active?}
      class="inline-flex items-center gap-1 text-[10px] font-medium text-info ml-auto"
    >
      <.icon name="hero-arrow-path" class="size-3 animate-spin" />
      <%= cond do %>
        <% @affects == "inspecting" -> %>
          Scanning image...
        <% @affects == "scanning" -> %>
          Scanning repo...
        <% true -> %>
          Loading...
      <% end %>
    </span>
    <span
      :if={@done? && !@active?}
      class="inline-flex items-center gap-1 text-[10px] font-medium text-success/50 ml-auto"
    >
      <.icon name="hero-check-mini" class="size-3" /> Discovered
    </span>
    """
  end

  attr :count, :integer, default: 3

  defp skeleton_rows(assigns) do
    ~H"""
    <div class="space-y-3 animate-pulse">
      <div :for={_ <- 1..@count} class="rounded-lg bg-base-200/30 p-3">
        <div class="h-3 bg-base-content/5 rounded w-1/3 mb-2"></div>
        <div class="flex gap-2">
          <div class="h-8 bg-base-content/5 rounded flex-1"></div>
          <div class="h-8 bg-base-content/5 rounded flex-1"></div>
        </div>
      </div>
    </div>
    """
  end

  @enrichment_stage_order ~w(inspecting scanning merging)
  defp stage_affects?(current, target), do: current == target

  defp stage_past?(current, target) do
    current_idx = Enum.find_index(@enrichment_stage_order, &(&1 == current)) || -1
    target_idx = Enum.find_index(@enrichment_stage_order, &(&1 == target)) || 99
    current_idx > target_idx
  end

  defp recompute_suggestions(socket) do
    env_vars = socket.assigns.env_vars
    domain = socket.assigns[:domain] || ""
    companion_names = Enum.map(socket.assigns.compose_services, fn svc -> svc[:name] end)

    db_suggestions =
      DatabaseDetector.detect(env_vars)
      |> Enum.map(fn suggestion ->
        companion_slug = "#{suggestion.db_type}-companion"
        Map.put(suggestion, :resolved?, companion_slug in companion_names)
      end)

    socket
    |> assign(:db_suggestions, db_suggestions)
    |> assign(:infra_suggestions, InfraDetector.detect(env_vars, domain: domain))
  end

  defp non_blank(""), do: nil
  defp non_blank(nil), do: nil
  defp non_blank(val), do: val

  defp sensitive_key?(nil), do: false

  defp sensitive_key?(key) do
    key = String.upcase(key)

    String.contains?(key, "PASSWORD") or String.contains?(key, "SECRET") or
      String.contains?(key, "KEY") or String.contains?(key, "TOKEN")
  end

  defp format_exposure("public"), do: "Public"
  defp format_exposure("sso_protected"), do: "SSO Protected"
  defp format_exposure("private"), do: "Private"
  defp format_exposure("service"), do: "Service (proxy-only)"
  defp format_exposure(other), do: to_string(other)

  defp image_display_name(image) do
    image
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.first()
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
    |> then(fn s -> if String.length(s) < 2, do: "custom-app", else: s end)
  end

  defp get_or_create_template_from_entry(entry) do
    slug = slugify(entry.name)

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
          {:error, _} -> struct(Homelab.Catalog.AppTemplate, Map.put(attrs, :id, nil))
        end
    end
  end

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

  defp deduplicate_entries(entries) do
    entries
    |> Enum.group_by(fn e ->
      String.downcase(e.name || "") |> String.replace(~r/[\s_\-]+/, "")
    end)
    |> Enum.map(fn {_key, group} ->
      Enum.max_by(group, fn e ->
        length(e.required_ports) + length(e.required_volumes) + map_size(e.default_env) +
          if(e.description && e.description != "", do: 1, else: 0) +
          if(e.logo_url, do: 2, else: 0)
      end)
    end)
  end

  defp parse_port_params(nil), do: []

  defp parse_port_params(ports_map) when is_map(ports_map) do
    alias Homelab.Catalog.Enrichers.PortRoles

    ports_map
    |> Enum.sort_by(fn {idx, _} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, port} ->
      role = port["role"]
      role = if role in [nil, "", "other"], do: PortRoles.infer(port["internal"]), else: role

      %{
        "internal" => port["internal"],
        "external" => port["external"],
        "description" => port["description"] || "",
        "optional" => port["optional"] == "true",
        "role" => role,
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
        "description" => vol["description"] || "",
        "optional" => vol["optional"] == "true"
      }
    end)
  end
end
