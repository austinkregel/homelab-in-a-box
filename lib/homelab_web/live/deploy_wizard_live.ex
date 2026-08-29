defmodule HomelabWeb.DeployWizardLive do
  use HomelabWeb, :live_view

  alias Homelab.Catalog
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.RuntimeSpec
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Deployments.VolumeSpec
  alias Homelab.Catalog.CatalogEntry
  alias Homelab.Catalog.Dedup
  alias Homelab.Catalog.MetadataEnricher
  alias Homelab.Catalog.Enrichers.ComposeParser
  alias Homelab.Catalog.Enrichers.DatabaseDetector
  alias Homelab.Catalog.Enrichers.InfraDetector
  alias Homelab.Networking.Hostname
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
      # Set when the operator names an image that an already-existing template does not
      # run. Becomes the new deployment's image_override rather than a rewrite of the
      # shared template — see select_custom/3.
      |> assign(:image_override, nil)
      # Advanced settings, held in assigns rather than form params: the review step has
      # two layouts (form and visual), and threading hidden inputs through both is how
      # they drift apart. These were editable only AFTER deploying, so a GPU or
      # multi-port app always came up wrong once and needed an immediate recreate.
      |> assign(:adv_memory_mb, "")
      |> assign(:adv_cpu_shares, "")
      |> assign(:adv_routed_port, "")
      |> assign(:adv_sticky, false)
      |> assign(:adv_restart_policy, "on-failure")
      # Kernel privileges, at CREATE time. An app that needs NET_ADMIN or a device to
      # function at all cannot be deployed first and fixed afterwards — it fails its
      # healthcheck, the release rolls back, and the Runtime card that would have fixed
      # it never becomes reachable.
      |> assign(:adv_capabilities_add, "")
      |> assign(:adv_devices, "")
      |> assign(:adv_sysctls, "")
      # Whose network stack this container will use. Offered at CREATE rather than only
      # afterwards, because an app meant to live behind a VPN must not come up outside
      # it even once — the first boot is the leak.
      |> assign(:network_parent_id, nil)
      |> assign(:netns_candidates, [])
      |> assign(:enriching, nil)
      |> assign(:custom_image, "")
      |> assign(:custom_name, "")
      |> assign(:compose_yaml, "")
      |> assign(:compose_project_dir, "")
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
      |> put_domain("")
      |> assign(:exposure_mode, "public")
      # Access model: top-level access ("proxy"/"host"/"internal") + proxy auth.
      |> assign(:access, "proxy")
      |> assign(:auth, "public")
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

  defp maybe_load_from_params(
         %{assigns: %{deploy_type: nil}} = socket,
         %{"type" => type},
         _already_loaded
       )
       when type in ~w(container compose stack) do
    assign(socket, :deploy_type, type)
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

  # Enrichment runs in an UNLINKED Task, and it used to pattern-match `{:ok, enriched} =`
  # on the result. An image we cannot inspect -- private, rate-limited, auth-walled, all
  # ordinary outcomes for a registry SEARCH result -- returns {:error, _}, raising a
  # MatchError that killed the task silently. No :enrichment_complete ever arrived, so
  # `@enriching` stayed "inspecting" forever and the ports/volumes cards rendered a
  # skeleton placeholder in place of their editors, permanently. The operator saw a
  # shimmering box where the form should be and no way to add anything.
  #
  # A failed inspection is a non-event: we simply know nothing extra about the image.
  # Say so, and give the operator the form.
  defp enrichment_result(entry, pid) do
    case MetadataEnricher.enrich(entry, progress: pid) do
      {:ok, enriched} -> {:enrichment_complete, enriched}
      other -> {:enrichment_failed, other}
    end
  rescue
    # enrich/2 does not return an error -- it RAISES, somewhere down in the registry
    # HTTP calls. Which is precisely why the old `{:ok, enriched} =` match was fatal:
    # the exception took the unlinked Task with it and no message was ever sent.
    error -> {:enrichment_failed, error}
  catch
    :exit, reason -> {:enrichment_failed, {:exit, reason}}
  end

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
              "protocol" => Access.port_protocol(p),
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

      send(pid, enrichment_result(entry, pid))
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
      send(pid, enrichment_result(entry, pid))
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

      # A slug collision used to silently discard the image the operator just typed:
      # the existing template was reused as-is, so asking for `nginx:1.25` deployed
      # whatever the old template said, with no warning. Rewriting the template
      # instead would be worse — it is shared, so it would move every other
      # deployment of that slug.
      #
      # So the typed image becomes this DEPLOYMENT's override, which is exactly what
      # per-deployment images are for.
      {template, image_override} =
        case Catalog.get_app_template_by_slug(slug) do
          {:ok, t} ->
            {t, if(t.image == image, do: nil, else: image)}

          {:error, :not_found} ->
            case Catalog.create_app_template(template_attrs) do
              {:ok, t} -> {t, nil}
              {:error, _} -> {struct(Homelab.Catalog.AppTemplate, template_attrs), nil}
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

          send(pid, enrichment_result(entry, pid))
        end)
      end

      socket =
        socket
        |> assign(:selected_template, template)
        |> assign(:image_override, image_override)
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

  def handle_event("advanced_changed", %{"advanced" => advanced}, socket) do
    {:noreply,
     socket
     |> assign(:adv_memory_mb, advanced["memory_mb"] || "")
     |> assign(:adv_cpu_shares, advanced["cpu_shares"] || "")
     |> assign(:adv_routed_port, advanced["routed_port"] || "")
     |> assign(:adv_restart_policy, advanced["restart_policy"] || "on-failure")
     |> assign(:adv_sticky, advanced["sticky"] == "true")
     |> assign(:adv_capabilities_add, advanced["capabilities_add"] || "")
     |> assign(:adv_devices, advanced["devices"] || "")
     |> assign(:adv_sysctls, advanced["sysctls"] || "")}
  end

  # --- Events: Compose ---

  def handle_event("parse_compose", %{"compose_yaml" => yaml} = params, socket) do
    project_dir = String.trim(params["project_dir"] || "")

    socket =
      socket
      |> assign(:compose_yaml, yaml)
      |> assign(:compose_project_dir, project_dir)

    case ComposeParser.parse_all(yaml, project_dir: project_dir) do
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
            "protocol" => "tcp",
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
        "exposure" -> assign_exposure(socket, value)
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
      |> put_domain(network_params["domain"] || socket.assigns.domain)
      |> assign(:tenant_id, non_blank(network_params["tenant_id"]) || socket.assigns.tenant_id)
      # `""` is a real value — the operator choosing "its own network" — so it must not
      # fall through to the previous choice the way a blank domain does.
      |> assign(
        :network_parent_id,
        Map.get(network_params, "network_parent_id", socket.assigns.network_parent_id)
      )
      # The candidate list is per-space, so changing space changes it.
      |> assign_netns_candidates()
      # Host ports and host networking are unreachable from inside another container's
      # namespace. Silently leaving one selected would deploy an access mode the
      # changeset then refuses, with the error pointing at a field two steps back.
      |> reset_access_if_netns()

    {:noreply, socket}
  end

  def handle_event("update_network", params, socket) do
    socket =
      socket
      |> assign_exposure(params["exposure_mode"] || socket.assigns.exposure_mode)

    {:noreply, socket}
  end

  # Access model: choose the access mode (proxy/host/internal) and, for proxy,
  # the auth level. Both derive the canonical `exposure_mode`.
  def handle_event("update_access", %{"access" => access}, socket) do
    if netns_forbidden_access?(socket.assigns.network_parent_id, access) do
      {:noreply, socket}
    else
      exposure = Access.exposure_for(access, socket.assigns.auth)
      {:noreply, socket |> assign(:access, access) |> assign(:exposure_mode, exposure)}
    end
  end

  def handle_event("update_auth", %{"auth" => auth}, socket) do
    exposure = Access.exposure_for("proxy", auth)

    {:noreply,
     socket |> assign(:access, "proxy") |> assign(:auth, auth) |> assign(:exposure_mode, exposure)}
  end

  # Keep the config-step assigns in sync as the user edits, so navigation and the
  # Review step reflect the latest ports/volumes/env (no stale-assign bug).
  def handle_event("config_changed", params, socket) do
    {:noreply,
     socket
     |> assign(:ports, sync_ports(params["ports"], socket.assigns.ports))
     |> assign(:volumes, sync_volumes(params["volumes"], socket.assigns.volumes))
     |> assign(:env_vars, sync_env(params["env"], socket.assigns.env_vars))}
  end

  # --- Events: Deploy ---

  def handle_event("deploy", params, socket) do
    tenant_id = params["tenant_id"] || socket.assigns.tenant_id
    exposure_mode = params["exposure_mode"] || socket.assigns.exposure_mode
    # A domain only applies to reverse-proxy access; host/internal ignore it.
    domain_attrs =
      if Access.access_of(exposure_mode) == "proxy",
        do: domain_attrs(params["domain"] || socket.assigns.domain),
        else: %{domain: nil, additional_domains: []}

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

      attrs =
        %{
          tenant_id: String.to_integer(tenant_id),
          env_overrides: env_overrides,
          image_override: socket.assigns[:image_override]
        }
        |> Map.put(:app_template_id, template.id)
        |> Map.merge(domain_attrs)
        |> Map.merge(advanced_attrs(socket))
        |> Map.merge(netns_attrs(socket))

      case Homelab.Deployments.deploy_now(attrs) do
        {:ok, _deployment} ->
          {:noreply,
           socket
           |> put_flash(:info, "#{template.name} deployment started!")
           |> push_navigate(to: ~p"/")}

        # `inspect(changeset.errors)` put a keyword list on screen with its `%{count}`
        # placeholders still unresolved. Same messages, rendered as a sentence.
        {:error, %Ecto.Changeset{} = changeset} ->
          {:noreply,
           put_flash(socket, :error, "Deployment failed: #{changeset_message(changeset)}")}

        {:error, reason} ->
          {:noreply, put_flash(socket, :error, "Deployment failed: #{inspect(reason)}")}
      end
    end
  end

  def handle_event("deploy_compose", params, socket) do
    tenant_id = params["tenant_id"] || socket.assigns.tenant_id
    domain_attrs = domain_attrs(params["domain"] || socket.assigns.domain)
    exposure_mode = params["exposure_mode"] || socket.assigns.exposure_mode

    if tenant_id == nil or tenant_id == "" do
      {:noreply, put_flash(socket, :error, "Please select a space.")}
    else
      main_template = socket.assigns.selected_template
      env_overrides = build_env_overrides(params)
      ports = parse_port_params(params["ports"])
      volumes = parse_volume_params(params["volumes"])

      # The config step edits a FLATTENED, deduped view of every service's ports, volumes
      # and env — and this handler used to read each service's RAW parsed values instead,
      # so every edit made on that screen was silently discarded.
      #
      # It bites hardest on folder mounts. Compose writes them relative (`./config:/config`),
      # which cannot be resolved without the project directory, so the config step exists
      # precisely to let the operator supply the real host path — and then the import used
      # the relative one anyway, failed volume validation, dropped the service, and reported
      # "Could not start the deployment". The wizard looked like it did not support folder
      # mounts at all.
      #
      # Edits are keyed back to services by the SAME key the flattening deduped on, which is
      # the only correspondence that exists.
      edits = %{
        volumes: index_by(volumes, "container_path"),
        ports: index_by(ports, "internal"),
        env: index_by(parse_env_rows(params), "key")
      }

      main_result =
        if main_template && main_template.id do
          template_updates = %{
            ports: ports,
            volumes: volumes,
            exposure_mode: String.to_existing_atom(exposure_mode)
          }

          Catalog.update_app_template(main_template, template_updates)

          Homelab.Deployments.create_deployment(
            %{
              tenant_id: String.to_integer(tenant_id),
              app_template_id: main_template.id,
              env_overrides: env_overrides
            }
            |> Map.merge(domain_attrs)
            # The Advanced panel is rendered on the review step for BOTH paths, but only
            # the plain "deploy" handler ever read it — a compose import silently threw
            # away every limit, routed port and restart policy the operator had just
            # filled in, with the panel still showing them on screen.
            |> Map.merge(advanced_attrs(socket))
          )
        end

      # Which compose service is the APP. `deploy_release/2` needs one: it deploys the
      # companions first and the app last, and only the app's ingress is published.
      #
      # When a template was chosen separately, that is the app and every compose service
      # is a companion. When it was NOT — a plain "paste a compose file" import, which is
      # the common case — nothing used to fill the role: `main_result` stayed nil, so the
      # handler created every deployment ROW and then fell through to "Could not start the
      # deployment", leaving orphaned `:pending` rows and planning no release at all. The
      # import dead-ended at exactly the point it looked like it had worked.
      primary_name =
        if main_result, do: nil, else: ComposeParser.primary_name(socket.assigns.compose_services)

      # Create the compose deployment ROWS. Companions carry no domain — they are internal
      # dependencies, never ingress-published. The release saga deploys them.
      compose_deployments =
        socket.assigns.compose_services
        |> Enum.map(fn svc ->
          primary? = primary_name != nil and svc[:name] == primary_name
          slug = slugify(svc[:name] || "compose-service")
          image = svc[:image] || ""

          # This service's rows, with whatever the operator changed on the config step
          # applied over them. Without this the screen is decorative on the compose path.
          svc_ports = apply_edits(svc[:ports], edits.ports, "internal")
          svc_volumes = apply_edits(svc[:volumes], edits.volumes, "container_path", "path")
          svc_env = apply_edits(svc[:env], edits.env, "key")

          template_attrs = %{
            slug: slug,
            name: svc[:name] || slug,
            version: "latest",
            image: image,
            description: "From compose file",
            source: "compose",
            source_id: image,
            ports: svc_ports,
            # Through VolumeSpec, so a companion's folder mounts keep their host paths.
            # A database companion is exactly where dropping them hurts most.
            volumes: VolumeSpec.parse(svc_volumes),
            default_env:
              svc_env
              |> Enum.filter(fn %{"value" => v} -> v != "" end)
              |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end),
            required_env:
              svc_env
              |> Enum.filter(fn %{"value" => v} -> v == "" end)
              |> Enum.map(fn %{"key" => k} -> k end),
            depends_on: svc[:depends_on] || [],
            exposure_mode: String.to_existing_atom(exposure_mode),
            # What the service is allowed to ask the KERNEL for. Dropping these was the
            # difference between an import that looks complete and a container that
            # cannot do its job — a VPN client with no NET_ADMIN starts, fails to open
            # a tunnel, and reports it as its own error.
            capabilities_add: blank_to_nil_list(svc[:capabilities_add]),
            capabilities_drop: blank_to_nil_list(svc[:capabilities_drop]),
            devices: blank_to_nil_list(svc[:devices]),
            sysctls: svc[:sysctls] || %{},
            # Both already existed on the template and were still never imported.
            command: svc[:command],
            entrypoint: svc[:entrypoint]
          }

          with {:ok, template} <- resolve_compose_template(slug, template_attrs) do
            svc_env_overrides =
              svc_env
              |> Enum.reject(fn %{"value" => v} -> v == "" end)
              |> Map.new(fn %{"key" => k, "value" => v} -> {k, v} end)

            attrs =
              %{
                tenant_id: String.to_integer(tenant_id),
                app_template_id: template.id,
                env_overrides: svc_env_overrides,
                # This compose service's shape belongs to THIS deployment, not to a
                # template other deployments inherit from.
                ports_override: blank_to_nil_list(template_attrs.ports),
                volumes_override: blank_to_nil_list(template_attrs.volumes),
                # `restart:` has a home (`restart_policy_override`) but has never been
                # imported, so every compose service arrived on the platform default
                # regardless of what its file said.
                restart_policy_override: svc[:restart]
              }
              # The Advanced panel describes ONE workload, so it applies to the app and
              # not to its companions — a routed port or memory ceiling copied onto five
              # services is not what the operator asked for. The domain and its aliases
              # ride along for the same reason: companions are internal, and a hostname
              # copied onto five of them is five routers fighting over one name.
              |> then(fn attrs ->
                if primary?,
                  do: attrs |> Map.merge(advanced_attrs(socket)) |> Map.merge(domain_attrs),
                  else: attrs
              end)

            case Homelab.Deployments.create_deployment(attrs) do
              {:ok, deployment} ->
                {:ok, {primary?, deployment}}

              {:error, changeset} ->
                {:error, {svc[:name] || slug, changeset_message(changeset)}}
            end
          else
            {:error, message} -> {:error, {svc[:name] || slug, message}}
          end
        end)

      {created, failures} =
        Enum.split_with(compose_deployments, &match?({:ok, _}, &1))

      compose_deployments = Enum.map(created, fn {:ok, entry} -> entry end)
      failures = Enum.map(failures, fn {:error, failure} -> failure end)

      {app_deployment, companion_deployments} =
        resolve_compose_app(main_result, compose_deployments)

      cond do
        # Nothing usable came out. Say WHICH service and WHY — the old flash named
        # neither, which is how "this wizard does not support folder mounts" became the
        # obvious conclusion from "my compose file imported to nothing".
        is_nil(app_deployment) ->
          {:noreply, put_flash(socket, :error, compose_failure_message(failures))}

        failures != [] ->
          {:ok, _release} =
            Homelab.Deployments.deploy_release(app_deployment, companion_deployments)

          {:noreply,
           socket
           |> put_flash(
             :error,
             "Deployed #{length(companion_deployments) + 1} service(s), but skipped " <>
               "#{describe_failures(failures)}"
           )
           |> push_navigate(to: ~p"/")}

        true ->
          {:ok, _release} =
            Homelab.Deployments.deploy_release(app_deployment, companion_deployments)

          {:noreply,
           socket
           |> put_flash(
             :info,
             "Deployment started — provisioning #{length(companion_deployments) + 1} service(s)."
           )
           |> push_navigate(to: ~p"/")}
      end
    end
  end

  defp compose_failure_message([]), do: "Could not start the deployment."

  defp compose_failure_message(failures),
    do: "Could not start the deployment — #{describe_failures(failures)}"

  defp describe_failures(failures) do
    Enum.map_join(failures, "; ", fn {name, message} -> "#{name}: #{message}" end)
  end

  # Splits the created rows into the one app and its companions.
  #
  # A separately-chosen template is the app and every compose service is a companion.
  # Otherwise the app is the row flagged primary during creation; the fallback to the
  # first row matters when the primary service's template could not be resolved, and is
  # still better than the old behaviour of deploying nothing.
  defp resolve_compose_app({:ok, main_deployment}, compose_deployments) do
    {main_deployment, Enum.map(compose_deployments, fn {_primary?, d} -> d end)}
  end

  defp resolve_compose_app(_main_result, compose_deployments) do
    case Enum.split_with(compose_deployments, fn {primary?, _d} -> primary? end) do
      {[{_primary?, app} | extra], companions} ->
        {app, Enum.map(extra ++ companions, fn {_primary?, d} -> d end)}

      {[], [{_primary?, app} | companions]} ->
        {app, Enum.map(companions, fn {_primary?, d} -> d end)}

      {[], []} ->
        {nil, []}
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
      |> Dedup.deduplicate_entries()

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

      # Discovery lands SECONDS after the operator reaches this step, by which time they
      # may already be typing. Rebuilding the env list wholesale from the template threw
      # away everything they had entered -- the form appeared to wipe itself for no
      # reason, mid-keystroke. Ports and volumes were already merged; env was not.
      env_vars =
        merge_env_vars(
          socket.assigns.env_vars,
          build_env_var_list(
            updated_template.default_env || %{},
            updated_template.required_env || []
          )
        )

      existing_port_internals = MapSet.new(socket.assigns.ports, fn p -> p["internal"] end)

      enriched_ports =
        Enum.map(enriched_entry.required_ports, fn port ->
          %{
            "internal" => port["internal"],
            "external" => port["external"],
            "description" => port["description"],
            "role" => port["role"] || "other",
            "protocol" => Access.port_protocol(port),
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

      # Through VolumeSpec: a discovered volume can legitimately carry a type/source (a
      # compose-derived entry does), and rebuilding it from container_path alone would
      # downgrade a folder mount to an empty named volume.
      enriched_vols = VolumeSpec.parse(enriched_entry.required_volumes)

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

  # Discovery failed. That is not a deploy failure -- it just means we learned nothing
  # extra about the image, and the operator configures it by hand. Clearing :enriching is
  # what releases the ports/volumes editors from their skeleton state.
  def handle_info({:enrichment_failed, reason}, socket) do
    require Logger
    Logger.info("[DeployWizard] Image inspection failed, configure by hand: #{inspect(reason)}")

    {:noreply,
     socket
     |> assign(:enriching, nil)
     |> put_flash(
       :info,
       "Couldn't inspect that image — configure its ports and volumes by hand below."
     )}
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
      notification_count={@notification_count}
      notifications={@notifications}
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
            adv_memory_mb={@adv_memory_mb}
            adv_cpu_shares={@adv_cpu_shares}
            adv_routed_port={@adv_routed_port}
            adv_restart_policy={@adv_restart_policy}
            adv_sticky={@adv_sticky}
            adv_capabilities_add={@adv_capabilities_add}
            adv_devices={@adv_devices}
            adv_sysctls={@adv_sysctls}
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
              compose_project_dir={@compose_project_dir}
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
              domain_preview={@domain_preview}
              access={@access}
              auth={@auth}
              exposure_mode={@exposure_mode}
              tenant_id={@tenant_id}
              tenants={@tenants}
              network_parent_id={@network_parent_id}
              netns_candidates={@netns_candidates}
            />
            <.step_config
              :if={@step == "config"}
              deploy_type={@deploy_type}
              selected_template={@selected_template}
              selected_entry={@selected_entry}
              enriching={@enriching}
              exposure_mode={@exposure_mode}
              ports={@ports}
              adv_routed_port={@adv_routed_port}
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
              adv_memory_mb={@adv_memory_mb}
              adv_cpu_shares={@adv_cpu_shares}
              adv_routed_port={@adv_routed_port}
              adv_restart_policy={@adv_restart_policy}
              adv_sticky={@adv_sticky}
              adv_capabilities_add={@adv_capabilities_add}
              adv_devices={@adv_devices}
              adv_sysctls={@adv_sysctls}
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
            compose_project_dir={@compose_project_dir}
            compose_error={@compose_error}
            compose_services={@compose_services}
          />
        <% @deploy_type == "stack" -> %>
          <.compose_input
            compose_yaml={@compose_yaml}
            compose_project_dir={@compose_project_dir}
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

        <div class="mt-3">
          <label class="block text-xs font-medium text-base-content/60 mb-1">
            Project directory on the host <span class="text-base-content/30">(optional)</span>
          </label>
          <input
            type="text"
            name="project_dir"
            value={@compose_project_dir}
            placeholder="/home/you/homelab"
            class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-3 placeholder:text-base-content/20 focus:ring-2 focus:ring-primary/50"
          />
          <p class="mt-1 text-[11px] text-base-content/40 leading-snug">
            The directory this compose file lives in. Compose resolves relative folder
            mounts (<code class="font-mono">./data</code>) against it, and prefixes named
            volumes with its basename — so without it we cannot tell which host directory
            or which volume your data is actually in, and you will be asked for each path
            by hand.
          </p>
        </div>

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

      <.form
        for={to_form(%{})}
        id="config-form"
        phx-change="config_changed"
        phx-submit="config_changed"
        class="contents"
      >
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
            <%!-- Placeholder for rows still being discovered — never for the editor. --%>
            <.skeleton_rows :if={@enriching == "inspecting" && @ports == []} count={2} />
            <div>
              <p
                :if={@exposure_mode == "host"}
                class="text-[11px] text-base-content/40 mb-2 leading-snug"
              >
                Host-ports access: each listed port binds to the host. Set the host port for each.
              </p>
              <p
                :if={@exposure_mode == "host_network"}
                class="text-[11px] text-base-content/40 mb-2 leading-snug"
              >
                Host-network access: the container listens on these ports
                <span class="font-medium">on the host itself</span>
                — there is nothing to map, so no host port to set. They're listed here for the
                healthcheck and for your own record.
              </p>
              <p
                :if={@exposure_mode not in ["host", "host_network"]}
                class="text-[11px] text-base-content/40 mb-2 leading-snug"
              >
                These are the container's ports. They're reached through the reverse proxy — choose
                <span class="font-medium">Host ports</span>
                access on the previous step to bind them to the host.
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
                    <div class="w-20">
                      <label class="block text-[10px] text-base-content/30 mb-0.5">Proto</label>
                      <select
                        name={"ports[#{idx}][protocol]"}
                        class="w-full rounded-md bg-base-200 border-0 text-xs text-base-content py-1.5 px-1.5 focus:ring-2 focus:ring-primary/50"
                      >
                        <option
                          :for={proto <- ~w(tcp udp)}
                          value={proto}
                          selected={proto == Access.port_protocol(port)}
                        >
                          {String.upcase(proto)}
                        </option>
                      </select>
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
                  <%!-- A UDP port cannot be reached through Traefik, whose http services
                     speak TCP only. Said at the point of choice rather than left to be
                     discovered after a clean-looking deploy that routes nothing. --%>
                  <p
                    :if={Access.udp?(port) && @exposure_mode not in ~w(host host_network)}
                    class="mt-1 text-[10px] text-warning"
                  >
                    UDP is not proxied — use Host ports access to publish it.
                  </p>
                  <%!-- Host-ports access binds every listed port, so there is nothing to
                     tick -- the host port is the only open question. --%>
                  <div :if={@exposure_mode == "host"} class="flex items-center gap-2 mt-1.5">
                    <label class="text-[10px] text-base-content/40">Host port</label>
                    <input
                      type="text"
                      name={"ports[#{idx}][external]"}
                      value={port["external"] || port["internal"]}
                      placeholder={port["internal"]}
                      class="w-20 rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1 px-2 focus:ring-2 focus:ring-primary/50"
                    />
                    <input type="hidden" name={"ports[#{idx}][published]"} value="true" />
                  </div>
                  <%!-- A proxied app binds the ports Traefik is NOT carrying, per port: a
                     git server's web UI belongs behind the proxy and its SSH port cannot
                     go there at all. The routed port is excluded on a protected app --
                     the auth is middleware on the ROUTE, so a host binding on that port
                     would be the app with nothing in front of it. --%>
                  <div
                    :if={@exposure_mode in ~w(public sso_protected private)}
                    class="flex items-center gap-2 mt-1.5"
                  >
                    <label class={[
                      "flex items-center gap-1.5",
                      if(wizard_guarded_port?(port, @adv_routed_port, @exposure_mode, @ports),
                        do: "cursor-not-allowed opacity-40",
                        else: "cursor-pointer"
                      )
                    ]}>
                      <input
                        type="checkbox"
                        name={"ports[#{idx}][published]"}
                        value="true"
                        checked={
                          port["published"] in [true, "true"] and
                            not wizard_guarded_port?(
                              port,
                              @adv_routed_port,
                              @exposure_mode,
                              @ports
                            )
                        }
                        disabled={
                          wizard_guarded_port?(port, @adv_routed_port, @exposure_mode, @ports)
                        }
                        class="checkbox checkbox-xs checkbox-warning"
                      />
                      <span class="text-[10px] text-base-content/40">publish on host</span>
                    </label>
                    <input
                      type="text"
                      name={"ports[#{idx}][external]"}
                      value={port["external"] || port["internal"]}
                      placeholder={port["internal"]}
                      title="The host port this container port binds to when published."
                      class="w-20 rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1 px-2 focus:ring-2 focus:ring-primary/50"
                    />
                    <span
                      :if={wizard_guarded_port?(port, @adv_routed_port, @exposure_mode, @ports)}
                      class="text-[10px] text-base-content/30"
                    >
                      routed — reached through the proxy's access check
                    </span>
                  </div>
                  <input
                    :if={@exposure_mode not in ~w(host public sso_protected private)}
                    type="hidden"
                    name={"ports[#{idx}][external]"}
                    value={port["external"] || port["internal"]}
                  />
                </div>
                <button
                  type="button"
                  phx-click="add_port"
                  class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
                >
                  <.icon name="hero-plus-mini" class="size-3.5" /> Add port
                </button>
              </div>
            </div>
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
            <%!-- The skeleton stands in for rows we are still DISCOVERING; it must never
                  stand in for the editor itself. Gating the whole card on enrichment left
                  an operator staring at a shimmer with no way to add a volume, and if
                  enrichment never finished, that was permanent. --%>
            <.skeleton_rows :if={@enriching == "inspecting" && @volumes == []} count={1} />
            <div>
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
                  <div class="flex gap-2">
                    <div class="w-28 shrink-0">
                      <label class="block text-[10px] text-base-content/30 mb-0.5">
                        Storage
                      </label>
                      <select
                        name={"volumes[#{idx}][type]"}
                        class="w-full rounded-md bg-base-200 border-0 text-xs text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                      >
                        <option value="volume" selected={vol["type"] != "bind"}>Managed</option>
                        <option value="bind" selected={vol["type"] == "bind"}>Folder</option>
                      </select>
                    </div>
                    <div :if={vol["type"] == "bind"} class="flex-1">
                      <label class="block text-[10px] text-base-content/30 mb-0.5">
                        Host folder
                      </label>
                      <input
                        type="text"
                        name={"volumes[#{idx}][source]"}
                        value={vol["source"] || ""}
                        placeholder="/home/you/.homelab/app/data"
                        class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                      />
                    </div>
                    <div class="flex-1">
                      <label class="block text-[10px] text-base-content/30 mb-0.5">
                        Container path
                      </label>
                      <input
                        type="text"
                        name={"volumes[#{idx}][container_path]"}
                        value={vol["path"] || vol["container_path"] || ""}
                        placeholder="/data"
                        class="w-full rounded-md bg-base-200 border-0 text-xs font-mono text-base-content py-1.5 px-2 focus:ring-2 focus:ring-primary/50"
                      />
                    </div>
                  </div>
                  <p
                    :if={vol["type"] == "bind"}
                    class="mt-1 text-[10px] text-base-content/40 leading-snug"
                  >
                    Mounts a directory that already exists on the host — the data stays where
                    it is. Must be an absolute path: Docker reads a bare name as a named
                    volume and would mount an empty one instead.
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="add_volume"
                  class="flex items-center gap-1.5 text-xs font-medium text-primary hover:text-primary/80 transition-colors cursor-pointer"
                >
                  <.icon name="hero-plus-mini" class="size-3.5" /> Add volume
                </button>
              </div>
            </div>
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
                  <span class="text-[10px] text-base-content/30 ml-1.5 truncate">
                    {entry.full_ref}
                  </span>
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
      </.form>

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

        <%!-- Domain (only for reverse-proxy access) --%>
        <div :if={@access == "proxy"} class="rounded-lg bg-base-100 border border-base-content/5 p-3">
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
            Enables reverse proxy routing on ports 80/443. List several, separated by
            commas or spaces, to reach this app on more than one name.
          </p>
          <%!-- Echo back what the field PARSED, not what was typed. A comma-separated
                value used to be stored whole and became one unbuildable Traefik rule;
                now it splits, and the operator should be able to see that it did
                before deploying rather than infer it from a log afterwards. --%>
          <div :if={@domain_preview != []} class="mt-2 flex flex-wrap items-center gap-1.5">
            <span
              :for={{host, idx} <- Enum.with_index(@domain_preview)}
              class={[
                "rounded px-1.5 py-0.5 text-[10px] font-mono",
                idx == 0 && "bg-info/15 text-info",
                idx > 0 && "bg-base-200 text-base-content/50"
              ]}
            >
              {host}<span :if={idx == 0} class="ml-1 opacity-50">main</span>
            </span>
          </div>
        </div>

        <%!-- Whose network stack this container uses. Offered here rather than only
              after deploying, because an app meant to run behind a VPN must never come
              up outside it even once. --%>
        <div
          :if={@netns_candidates != []}
          class="rounded-lg bg-base-100 border border-base-content/5 p-3 lg:col-span-2"
        >
          <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
            <.icon name="hero-lock-closed-mini" class="size-4 text-warning" /> Network
          </h3>
          <select
            id="netns-select"
            name="network[network_parent_id]"
            class="w-full rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >
            <option value="" selected={@network_parent_id in [nil, ""]}>
              Its own network (default)
            </option>
            <option
              :for={candidate <- @netns_candidates}
              value={to_string(candidate.id)}
              selected={to_string(candidate.id) == to_string(@network_parent_id)}
            >
              Through {candidate.app_template.name}
            </option>
          </select>
          <p
            :if={@network_parent_id in [nil, ""]}
            class="text-[10px] text-base-content/30 mt-1.5"
          >
            Route all of this container's traffic through another container — how an app is
            put behind a VPN client.
          </p>
          <div
            :if={@network_parent_id not in [nil, ""]}
            class="rounded-md bg-warning/10 border border-warning/20 p-2.5 mt-2 text-[11px] text-base-content/70 leading-relaxed"
          >
            Every packet goes through that container, and nothing goes around it. This one gets
            no ports, no network aliases and no address of its own; anything else sharing that
            network reaches it on <code phx-no-curly-interpolation>localhost</code>, and Traefik reaches it via the other
            container. Host ports and host networking are not available.
          </div>
        </div>
      </.form>

      <%!-- Access (single coherent choice: proxy XOR host ports XOR host network XOR internal) --%>
      <div class="rounded-lg bg-base-100 border border-base-content/5 p-3 mt-4">
        <h3 class="text-sm font-semibold text-base-content flex items-center gap-2 mb-2">
          <.icon name="hero-shield-check-mini" class="size-4 text-success" /> Access
        </h3>
        <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2">
          <.access_option
            access="proxy"
            current={@access}
            icon="hero-globe-alt"
            title="Reverse proxy"
            desc="Served via Traefik at a domain"
          />
          <.access_option
            access="host"
            current={@access}
            icon="hero-server-stack"
            title="Host ports"
            desc="Bind container ports to the host"
            disabled={@network_parent_id not in [nil, ""]}
            disabled_desc="No ports of its own to bind while routing through another container"
          />
          <.access_option
            access="host_network"
            current={@access}
            icon="hero-signal"
            title="Host network"
            desc="Share the host's network namespace"
            disabled={@network_parent_id not in [nil, ""]}
            disabled_desc="A container has one network namespace, and this one uses another container's"
          />
          <.access_option
            access="internal"
            current={@access}
            icon="hero-lock-closed"
            title="Internal only"
            desc="No external access"
          />
        </div>

        <div :if={@access == "proxy"} class="mt-3">
          <label class="text-[11px] font-medium text-base-content/50">Authentication</label>
          <div class="grid grid-cols-3 gap-2 mt-1.5">
            <.auth_option auth="public" current={@auth} title="None" desc="Anyone with the domain" />
            <.auth_option
              auth="sso_protected"
              current={@auth}
              title="SSO"
              desc="Requires login"
            />
            <.auth_option
              auth="private"
              current={@auth}
              title="Private"
              desc="LAN / IP allowlist"
            />
          </div>
        </div>

        <div
          :if={@access == "host"}
          class="mt-2.5 rounded-md bg-warning/5 border border-warning/20 py-2 px-3"
        >
          <p class="text-[11px] text-base-content/40 leading-relaxed">
            Container ports bind directly to the host — set which on the next step. Not reverse-proxied.
          </p>
        </div>

        <div
          :if={@access == "host_network"}
          class="mt-2.5 rounded-md bg-warning/5 border border-warning/20 py-2 px-3"
        >
          <p class="text-[11px] text-base-content/40 leading-relaxed">
            The container runs in the host's network namespace — it listens on the host's ports
            directly, with nothing mapped. Pick this for apps that need broadcast or multicast
            discovery (mDNS, SSDP, DHCP), which a published port cannot forward. It gives up
            network isolation from the host: no tenant network, no reverse proxy, and no
            container-to-container DNS.
          </p>
        </div>

        <div
          :if={@access == "internal"}
          class="mt-2.5 rounded-md bg-info/5 border border-info/20 py-2 px-3"
        >
          <p class="text-[11px] text-base-content/40 leading-relaxed">
            No host ports and no public route. Reachable only on the container network.
          </p>
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

  # `disabled` rather than hidden: a tile that vanishes reads as a missing feature,
  # where a greyed one with a reason reads as a consequence of the choice above it.
  attr :access, :string, required: true
  attr :current, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :desc, :string, required: true
  attr :disabled, :boolean, default: false
  attr :disabled_desc, :string, default: nil

  defp access_option(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="update_access"
      phx-value-access={@access}
      disabled={@disabled}
      class={[
        "text-left py-2.5 px-3 rounded-md border-2 transition-all",
        if(@disabled, do: "opacity-40 cursor-not-allowed", else: "cursor-pointer"),
        if(@current == @access and not @disabled,
          do: "border-primary bg-primary/5",
          else: "border-base-content/5 bg-base-200/30"
        ),
        not @disabled && "hover:border-base-content/15"
      ]}
    >
      <.icon name={@icon} class="size-4 mb-1 text-primary" />
      <h4 class="text-xs font-semibold text-base-content">{@title}</h4>
      <p class="text-[10px] text-base-content/40 mt-0.5 leading-snug">
        {if(@disabled and @disabled_desc, do: @disabled_desc, else: @desc)}
      </p>
    </button>
    """
  end

  defp auth_option(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="update_auth"
      phx-value-auth={@auth}
      class={[
        "text-left py-2 px-2.5 rounded-md border-2 transition-all cursor-pointer",
        if(@current == @auth,
          do: "border-primary bg-primary/5",
          else: "border-base-content/5 bg-base-200/30 hover:border-base-content/15"
        )
      ]}
    >
      <h4 class="text-xs font-semibold text-base-content">{@title}</h4>
      <p class="text-[10px] text-base-content/40 mt-0.5 leading-snug">{@desc}</p>
    </button>
    """
  end

  # ============================================================
  # Step 5: Review & Deploy
  # ============================================================

  # Its own form, not nested in the deploy form — nested forms are invalid HTML and the
  # browser drops the inner one's fields. Writes to assigns, which `advanced_attrs/1`
  # reads at deploy time, so both review layouts get the same behaviour for free.
  attr :memory_mb, :string, required: true
  attr :cpu_shares, :string, required: true
  attr :routed_port, :string, required: true
  attr :restart_policy, :string, required: true
  attr :sticky, :boolean, required: true
  attr :capabilities_add, :string, required: true
  attr :devices, :string, required: true
  attr :sysctls, :string, required: true

  defp advanced_panel(assigns) do
    ~H"""
    <details class="rounded-lg bg-base-100 border border-base-content/5 p-3">
      <summary class="text-sm font-semibold text-base-content cursor-pointer flex items-center gap-2">
        <.icon name="hero-adjustments-horizontal-mini" class="size-4 text-primary" /> Advanced
        <span class="text-xs font-normal text-base-content/40">
          Optional — all of these are editable later
        </span>
      </summary>
      <.form
        for={to_form(%{}, as: :advanced)}
        id="advanced-form"
        phx-change="advanced_changed"
        class="mt-3 grid grid-cols-1 sm:grid-cols-2 gap-3"
      >
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">Memory limit (MB)</label>
          <input
            type="number"
            min="1"
            name="advanced[memory_mb]"
            value={@memory_mb}
            placeholder="Unlimited"
            class="rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">CPU shares</label>
          <input
            type="number"
            min="1"
            name="advanced[cpu_shares]"
            value={@cpu_shares}
            placeholder="Unlimited"
            class="rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          />
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">Routed port</label>
          <input
            type="number"
            min="1"
            max="65535"
            name="advanced[routed_port]"
            value={@routed_port}
            placeholder="Detected automatically"
            class="rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          />
          <p class="text-xs text-base-content/40">
            Which container port the proxy forwards to, for an app serving more than one.
          </p>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">Restart policy</label>
          <select
            name="advanced[restart_policy]"
            class="rounded-md bg-base-200 border-0 text-sm text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >
            <option
              :for={
                {value, label} <- [
                  {"on-failure", "On failure (up to 3 times)"},
                  {"always", "Always"},
                  {"unless-stopped", "Unless stopped"},
                  {"no", "Never"}
                ]
              }
              value={value}
              selected={@restart_policy == value}
            >
              {label}
            </option>
          </select>
        </div>
        <label class="flex items-center gap-2 text-sm text-base-content/70 sm:col-span-2">
          <input type="hidden" name="advanced[sticky]" value="false" />
          <input
            type="checkbox"
            name="advanced[sticky]"
            value="true"
            checked={@sticky}
            class="rounded border-base-content/20"
          /> Sticky sessions — pin each visitor to one replica
        </label>

        <div class="sm:col-span-2 pt-3 mt-1 border-t border-base-content/5">
          <h5 class="text-xs font-semibold text-base-content/70">Kernel privileges</h5>
          <p class="text-[10px] text-base-content/40 mt-0.5 leading-snug">
            Needed by VPN clients, USB/serial coordinators and anything managing its own
            network stack. Free text here; the deployment's Runtime card gives each of these
            a proper editor once it exists.
          </p>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">Capabilities added</label>
          <textarea
            name="advanced[capabilities_add]"
            rows="2"
            placeholder="NET_ADMIN"
            class="rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >{@capabilities_add}</textarea>
          <p class="text-xs text-base-content/40">One per line. The CAP_ prefix is optional.</p>
        </div>
        <div class="flex flex-col gap-1">
          <label class="text-xs font-medium text-base-content/50">Devices</label>
          <textarea
            name="advanced[devices]"
            rows="2"
            placeholder="/dev/net/tun"
            class="rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >{@devices}</textarea>
          <p class="text-xs text-base-content/40">
            One per line, <code phx-no-curly-interpolation>host[:container[:rwm]]</code>.
          </p>
        </div>
        <div class="flex flex-col gap-1 sm:col-span-2">
          <label class="text-xs font-medium text-base-content/50">Sysctls</label>
          <textarea
            name="advanced[sysctls]"
            rows="2"
            placeholder="net.ipv4.conf.all.src_valid_mark=1"
            class="rounded-md bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-2.5 focus:ring-2 focus:ring-primary/50"
          >{@sysctls}</textarea>
          <p class="text-xs text-base-content/40">
            One <code phx-no-curly-interpolation>key=value</code>
            per line. Only net.*, fs.mqueue.* and the kernel IPC limits.
          </p>
        </div>
      </.form>
    </details>
    """
  end

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

      <%!-- Outside the deploy form: nested forms are invalid HTML. --%>
      <.advanced_panel
        memory_mb={@adv_memory_mb}
        cpu_shares={@adv_cpu_shares}
        routed_port={@adv_routed_port}
        restart_policy={@adv_restart_policy}
        sticky={@adv_sticky}
        capabilities_add={@adv_capabilities_add}
        devices={@adv_devices}
        sysctls={@adv_sysctls}
      />

      <.form
        for={to_form(%{})}
        id="deploy-review-form"
        phx-submit={if(@deploy_type == "compose", do: "deploy_compose", else: "deploy")}
        class="space-y-3 mt-3"
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
                  name={"ports[#{idx}][protocol]"}
                  value={Access.port_protocol(port)}
                />
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
                <span :if={Access.udp?(port)} class="text-base-content/40">/udp</span>
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
                <%!-- type/source must ride along. Deploy is submitted from THIS form, so
                      a folder mount configured on the previous step died right here: the
                      hidden inputs rebuilt it from container_path alone and SpecBuilder
                      then minted an empty named volume in its place. --%>
                <input type="hidden" name={"volumes[#{idx}][type]"} value={vol["type"] || ""} />
                <input
                  type="hidden"
                  name={"volumes[#{idx}][source]"}
                  value={vol["source"] || ""}
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
                <span :if={vol["type"] == "bind"} class="text-base-content/40">
                  {vol["source"]} →
                </span>
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

        <%!-- Warning for host-network mode --%>
        <div
          :if={@exposure_mode == "host_network"}
          class="rounded-md bg-warning/5 border border-warning/20 py-2 px-3 flex items-start gap-2"
        >
          <.icon name="hero-signal-mini" class="size-4 text-warning mt-0.5 flex-shrink-0" />
          <p class="text-[11px] text-base-content/40 leading-relaxed">
            <span class="font-medium text-base-content/60">Host network:</span>
            The container shares the host's network namespace. Every port it listens on is open on
            the host directly — no mapping, no tenant network, and no Traefik route.
          </p>
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
          <.button
            type="submit"
            label="Deploy"
            class="px-6 py-2 rounded-lg bg-primary text-primary-content text-sm font-bold hover:bg-primary/90 transition-colors shadow-lg shadow-primary/20 cursor-pointer"
          >
            <.icon name="hero-rocket-launch-mini" class="size-4 inline mr-1" />
          </.button>
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
        <.advanced_panel
          memory_mb={@adv_memory_mb}
          cpu_shares={@adv_cpu_shares}
          routed_port={@adv_routed_port}
          restart_policy={@adv_restart_policy}
          sticky={@adv_sticky}
          capabilities_add={@adv_capabilities_add}
          devices={@adv_devices}
          sysctls={@adv_sysctls}
        />
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
              name={"ports[#{idx}][protocol]"}
              value={Access.port_protocol(port)}
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
            <%!-- Same as the review form: without these, deploying from Visual mode
                  silently downgrades every folder mount to an empty named volume. --%>
            <input
              :for={{vol, idx} <- Enum.with_index(@volumes)}
              type="hidden"
              name={"volumes[#{idx}][type]"}
              value={vol["type"] || ""}
            />
            <input
              :for={{vol, idx} <- Enum.with_index(@volumes)}
              type="hidden"
              name={"volumes[#{idx}][source]"}
              value={vol["source"] || ""}
            />
            <input
              :for={env <- @env_vars}
              type="hidden"
              name={"env_overrides[#{env["key"]}]"}
              value={env["value"] || ""}
            />
            <.button
              type="submit"
              label="Deploy"
              class="w-full px-6 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-bold hover:bg-primary/90 transition-colors shadow-lg shadow-primary/20 cursor-pointer flex items-center justify-center gap-2"
            >
              <.icon name="hero-rocket-launch-mini" class="size-4" />
            </.button>
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

  # The env editor's rows as rows, blanks KEPT — a blank value is not noise here, it is
  # what marks a variable required. `build_env_overrides/1` drops them because it builds
  # the override map; the compose path needs the distinction.
  defp parse_env_rows(params) do
    params["env"]
    |> Kernel.||(%{})
    |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} ->
      %{"key" => row["key"] || "", "value" => row["value"] || ""}
    end)
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

  # Derive access + auth from the canonical exposure_mode (keeps the three in sync
  # whichever path sets it: the Access buttons, update_network, or topology_change).
  defp assign_exposure(socket, exposure) when is_binary(exposure) and exposure != "" do
    socket
    |> assign(:exposure_mode, exposure)
    |> assign(:access, Access.access_of(exposure))
    |> assign(:auth, Access.auth_of(exposure))
  end

  defp assign_exposure(socket, _), do: socket

  # config_changed sync: merge the indexed form params back into the existing
  # rows, preserving fields the form doesn't render (descriptions, roles, etc.).
  # Whether this port is the one Traefik will forward to on an app whose proxy carries an
  # access check -- SSO's forwardAuth or private's ip allowlist. Middleware runs on the
  # ROUTE, so binding that port to the host would publish the app with the check skipped,
  # and `SpecBuilder.build_ports/1` drops it. Greying the box out here is the same rule
  # said before the deploy instead of after it.
  #
  # `:public` is proxied but guards nothing, so it is not included -- publishing its
  # routed port is a plain "also answer on the LAN", which is the operator's call.
  defp wizard_guarded_port?(port, adv_routed_port, exposure_mode, ports) do
    exposure_mode in ~w(sso_protected private) and
      to_string(port["internal"]) == wizard_routed_port(adv_routed_port, ports)
  end

  # An explicit pick in Advanced is a DECISION and wins, exactly as it does in
  # `SpecBuilder.routed_port/1`; with no pick, the guess is delegated rather than copied
  # so the port this greys out is always the port that actually gets routed.
  defp wizard_routed_port(adv, _ports) when is_binary(adv) and adv != "", do: String.trim(adv)
  defp wizard_routed_port(_adv, ports), do: SpecBuilder.guess_port(ports)

  defp sync_ports(params, existing) do
    merge_indexed(existing, params, fn row, p ->
      row
      |> put_present(p, "internal")
      |> put_present(p, "external")
      |> put_present(p, "role")
      |> put_present(p, "protocol")
      |> Map.put("published", p["published"] == "true")
    end)
  end

  # `type` and `source` ride along, or switching a row to Folder and typing its host path
  # would be discarded the moment the operator added or removed another row.
  defp sync_volumes(params, existing) do
    merge_indexed(existing, params, fn row, p ->
      row
      |> put_present(p, "container_path")
      |> put_present(p, "type")
      |> put_present(p, "source")
    end)
  end

  defp sync_env(params, existing) do
    merge_indexed(existing, params, fn row, p ->
      row |> put_present(p, "key") |> put_present(p, "value")
    end)
  end

  # What the operator typed WINS over what discovery found. A discovered key they have
  # not touched is added; a discovered key they HAVE filled in keeps their value. A key
  # they added themselves is never dropped just because the image did not mention it.
  defp merge_env_vars(existing, discovered) do
    typed = MapSet.new(existing, & &1["key"])

    new_keys = Enum.reject(discovered, &MapSet.member?(typed, &1["key"]))

    # Carry `required` forward from discovery so a newly-known required var still
    # announces itself, without touching the value.
    required = MapSet.new(discovered, & &1["key"])

    existing
    |> Enum.map(fn env ->
      if MapSet.member?(required, env["key"]) do
        found = Enum.find(discovered, &(&1["key"] == env["key"]))
        Map.put(env, "required", found["required"] || env["required"] || false)
      else
        env
      end
    end)
    |> Kernel.++(new_keys)
  end

  defp merge_indexed(existing, params, fun) when is_map(params) and is_list(existing) do
    existing
    |> Enum.with_index()
    |> Enum.map(fn {row, idx} ->
      case params[to_string(idx)] do
        nil -> row
        p -> fun.(row, p)
      end
    end)
  end

  defp merge_indexed(existing, _params, _fun), do: existing

  defp put_present(row, params, key) do
    case Map.fetch(params, key) do
      {:ok, value} -> Map.put(row, key, value)
      :error -> row
    end
  end

  # One definition, shared with the API serializer and the deployment page. The copy
  # that lived here missed `DATABASE_URL`, `*_PASS` and `*_DSN`, and treated
  # `PUBLIC_KEY` as a secret — see `Homelab.SecretKeys`.
  defp sensitive_key?(key), do: Homelab.SecretKeys.sensitive?(key)

  defp format_exposure("public"), do: "Public"
  defp format_exposure("sso_protected"), do: "SSO Protected"
  defp format_exposure("private"), do: "Private"
  defp format_exposure("host"), do: "Host ports"
  defp format_exposure("host_network"), do: "Host network"
  defp format_exposure("service"), do: "Service (proxy-only)"
  defp format_exposure(other), do: to_string(other)

  defp image_display_name(image) do
    image
    |> String.split("/")
    |> List.last()
    |> String.split(":")
    |> List.first()
  end

  # `:domain` is the raw field and `:domain_preview` is what `domain_attrs/1` would make
  # of it, kept together so they cannot disagree. The preview is derived rather than
  # stored because it is a READING of the field -- the moment it were assigned anywhere
  # separately it would be one edit behind, which for a field whose whole purpose is now
  # to show that it split correctly is worse than not showing it.
  defp put_domain(socket, value) do
    socket
    |> assign(:domain, value)
    |> assign(:domain_preview, Hostname.split(value))
  end

  # The domain field is ONE input that may name several hosts, so this is where "what
  # the operator typed" becomes "what the schema stores": the first hostname is the
  # deployment's `domain`, every other one an entry in `additional_domains` reaching the
  # same container on the same port.
  #
  # Splitting here rather than rejecting is the whole point. An operator standing up a
  # Matrix homeserver has two names -- `communication.ventures` and
  # `matrix.communication.ventures` -- and one box to put them in, and comma-separating
  # them is the obvious move. Before this, that value was stored whole and emitted whole:
  # one Traefik router with an unbuildable rule, one ACME order Let's Encrypt refused,
  # and an app reachable at neither name. The comma was never the mistake; the single
  # input was.
  #
  # Aliases are created bare -- no `path_prefix`, no `port` -- because that is the only
  # reading of a plain list of names: all of them, whole, to this app. Scoping one to a
  # path (Synapse's `/.well-known/matrix` delegation) is a deliberate act and belongs to
  # the Additional domains editor in deployment settings, which can express it.
  defp domain_attrs(value) do
    case Hostname.split_primary(value) do
      {nil, _aliases} ->
        %{domain: nil, additional_domains: []}

      {primary, aliases} ->
        %{
          domain: primary,
          additional_domains:
            Enum.map(aliases, &%{"host" => &1, "path_prefix" => nil, "port" => nil})
        }
    end
  end

  # Only the fields the operator actually filled in. A blank stays absent rather than
  # becoming an explicit override, so an untouched Advanced panel leaves the deployment
  # inheriting from its template exactly as before.
  defp advanced_attrs(socket) do
    limits =
      %{}
      |> put_number("memory_mb", socket.assigns.adv_memory_mb)
      |> put_number("cpu_shares", socket.assigns.adv_cpu_shares)

    %{}
    |> put_if(:resource_limits_override, if(limits == %{}, do: nil, else: limits))
    |> put_if(:routed_port, parse_int(socket.assigns.adv_routed_port))
    |> put_if(
      :restart_policy_override,
      if(socket.assigns.adv_restart_policy == "on-failure",
        do: nil,
        else: socket.assigns.adv_restart_policy
      )
    )
    |> put_if(:proxy_options, if(socket.assigns.adv_sticky, do: %{"sticky" => true}))
    # Left absent when blank rather than stored as [], so the template still wins —
    # same rule the rest of this function follows. An operator who wants to CLEAR what
    # the template grants does it on the Runtime card, which can express [].
    |> put_if(
      :capabilities_add_override,
      blank_to_nil_list(RuntimeSpec.parse_capabilities(socket.assigns.adv_capabilities_add))
    )
    |> put_if(
      :devices_override,
      blank_to_nil_list(parse_device_lines(socket.assigns.adv_devices))
    )
    |> put_if(:sysctls_override, blank_to_nil_map(parse_sysctl_lines(socket.assigns.adv_sysctls)))
  end

  # `/dev/net/tun` or `/dev/sda:/dev/xvda:rw`, one per line — the compose spelling, so
  # an operator can paste a line straight out of the file they are replacing.
  defp parse_device_lines(text) do
    (text || "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> RuntimeSpec.parse_devices()
  end

  defp parse_sysctl_lines(text) do
    (text || "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> RuntimeSpec.parse_sysctls()
  end

  defp blank_to_nil_map(map) when map_size(map) == 0, do: nil
  defp blank_to_nil_map(map), do: map

  # Deployments in the chosen space that could host this container's network namespace.
  # Excludes anything already inside another namespace (chains are not supported) and
  # host-networked containers (which have no namespace of their own to share).
  defp assign_netns_candidates(socket) do
    candidates =
      case socket.assigns.tenant_id do
        nil ->
          []

        "" ->
          []

        tenant_id ->
          tenant_id
          |> to_string()
          |> String.to_integer()
          |> Homelab.Deployments.list_deployments_for_tenant()
          |> Enum.filter(fn candidate ->
            is_nil(candidate.network_parent_id) and not Access.host_network_mode?(candidate)
          end)
          |> Enum.sort_by(& &1.app_template.name)
      end

    socket
    |> assign(:netns_candidates, candidates)
    # A donor selected and then made ineligible (space changed, container removed) must
    # not survive as an id pointing at nothing.
    |> then(fn socket ->
      if socket.assigns.network_parent_id in [nil, ""] or
           Enum.any?(
             candidates,
             &(to_string(&1.id) == to_string(socket.assigns.network_parent_id))
           ) do
        socket
      else
        assign(socket, :network_parent_id, nil)
      end
    end)
  end

  defp reset_access_if_netns(socket) do
    if netns_forbidden_access?(socket.assigns.network_parent_id, socket.assigns.access) do
      socket
      |> assign(:access, "proxy")
      |> assign(:exposure_mode, Access.exposure_for("proxy", socket.assigns.auth))
    else
      socket
    end
  end

  defp netns_forbidden_access?(parent_id, access) when parent_id not in [nil, ""],
    do: access in ["host", "host_network"]

  defp netns_forbidden_access?(_parent_id, _access), do: false

  defp netns_attrs(socket) do
    case socket.assigns.network_parent_id do
      id when id in [nil, ""] -> %{}
      id -> %{network_parent_id: to_string(id) |> String.to_integer()}
    end
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)

  defp put_number(map, key, value) do
    case parse_int(value) do
      nil -> map
      number -> Map.put(map, key, number)
    end
  end

  defp parse_int(value) do
    case Integer.parse(to_string(value)) do
      {number, _rest} when number > 0 -> number
      _ -> nil
    end
  end

  # A compose service whose name collides with an existing template used to REWRITE that
  # template — image, ports, volumes and env — and templates are shared by slug. So
  # importing a stack into one space silently changed what every other space's deployment
  # of that slug runs, on its next redeploy. Deploying app X in space B changed app X in
  # space A, with nothing said about it.
  #
  # Reuse an existing row only when it already describes the same image, which keeps
  # re-importing the same compose file idempotent. A genuinely different stack that
  # happens to name a service `db` or `redis` gets its own template instead of
  # overwriting someone else's. Nothing here mutates a shared row.
  defp resolve_compose_template(slug, attrs) do
    case Catalog.get_app_template_by_slug(slug) do
      {:ok, template} ->
        if template.image == attrs.image,
          do: {:ok, template},
          else: create_template(%{attrs | slug: unique_slug(slug)})

      {:error, :not_found} ->
        create_template(attrs)
    end
  end

  # `{:error, message}` rather than nil, because the alternative is what this used to do:
  # swallow the changeset, hand back nil, and let the caller's `reject(&is_nil/1)` delete
  # the service. A compose file whose folder mount could not be resolved imported to
  # NOTHING — no template, no deployment — under a flash that said "Could not start the
  # deployment", which names neither the service nor the reason.
  defp create_template(attrs) do
    case Catalog.create_app_template(attrs) do
      {:ok, template} -> {:ok, template}
      {:error, changeset} -> {:error, changeset_message(changeset)}
    end
  end

  # One definition, shared with the deployment page — see `HomelabWeb.ChangesetErrors`.
  # The copy that lived here printed the raw field name in front of every message, which
  # reads as "network parent id Docker Swarm cannot share a network namespace".
  defp changeset_message(%Ecto.Changeset{} = changeset),
    do: HomelabWeb.ChangesetErrors.to_sentence(changeset)

  # Indexes the config step's edited rows by the key the flattening deduped on.
  defp index_by(rows, key) do
    rows
    |> List.wrap()
    |> Enum.reject(&blank?(&1[key]))
    |> Map.new(&{to_string(&1[key]), &1})
  end

  # Overlays the operator's edits onto one service's rows, matched on `key` (with an
  # optional fallback key, since the compose parser names a mount path `path` and the
  # form names it `container_path`).
  #
  # Only rows this service actually declared are kept: a row the operator ADDED belongs
  # to whichever service they were looking at, and there is no way to know which — so
  # inventing an owner would silently attach one app's volume to another.
  defp apply_edits(rows, edited, key, fallback_key \\ nil) do
    rows
    |> List.wrap()
    |> Enum.map(fn row ->
      lookup = row[key] || (fallback_key && row[fallback_key])

      case Map.get(edited, to_string(lookup)) do
        nil -> row
        edit -> Map.merge(row, edit)
      end
    end)
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false

  defp unique_slug(slug), do: "#{slug}-#{System.unique_integer([:positive]) |> rem(10_000)}"

  # `[]` from a compose service that declared no ports means "nothing to publish", but an
  # empty override is NOT the same as no override — `Access.effective_ports/1` inherits
  # only on nil, so storing [] would win over the template rather than defer to it.
  defp blank_to_nil_list([]), do: nil
  defp blank_to_nil_list(nil), do: nil
  defp blank_to_nil_list(list), do: list

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

        # Through VolumeSpec, and carrying `type`/`source` — dropping them here forced
        # every catalog app onto a managed volume regardless of what the entry said, so
        # an app meant to read an existing library came up pointed at an empty one.
        volumes =
          Enum.map(entry.required_volumes, fn vol ->
            VolumeSpec.normalize(%{
              "container_path" => vol["container_path"] || vol["path"],
              "type" => vol["type"],
              "source" => vol["source"],
              "description" => vol["description"],
              "optional" => vol["optional"]
            })
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
          ports: ports,
          # What the app needs from the kernel, and whether it can host other
          # containers' networking. `blank_to_nil_list` so an entry that declares none
          # leaves the columns NULL rather than storing an empty override.
          capabilities_add: blank_to_nil_list(entry.capabilities_add),
          capabilities_drop: blank_to_nil_list(entry.capabilities_drop),
          devices: blank_to_nil_list(entry.devices),
          sysctls: entry.sysctls || %{},
          netns_donor_kind: entry.netns_donor_kind
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
      # `encode_entry/1` serializes the WHOLE struct, but this rebuilds it field by field
      # — so anything omitted here silently reverts to its defstruct default. Leaving
      # these five out meant the catalog's Gluetun entry round-tripped through the picker
      # with NET_ADMIN, /dev/net/tun and its sysctl stripped, and deployed a VPN client
      # that cannot open a tunnel while reporting success.
      capabilities_add: data["capabilities_add"] || [],
      capabilities_drop: data["capabilities_drop"] || [],
      devices: data["devices"] || [],
      sysctls: data["sysctls"] || %{},
      netns_donor_kind: data["netns_donor_kind"],
      alt_sources: data["alt_sources"] || [],
      stars: data["stars"] || 0,
      pulls: data["pulls"] || 0,
      official?: data["official?"] || false,
      deprecated?: data["deprecated?"] || false,
      auth_required?: data["auth_required?"] || false
    })
  end

  defp parse_port_params(ports), do: Homelab.Deployments.ConfigForm.parse_ports(ports)

  # Through VolumeSpec, so `type`/`source` survive. This used to rebuild each volume from
  # container_path alone and write the result back to the SHARED template (see
  # deploy/deploy_compose) -- which erased the host path of every folder mount
  # on that template, for every deployment of it, on one visit to the wizard.
  defp parse_volume_params(volumes), do: VolumeSpec.parse(volumes)
end
