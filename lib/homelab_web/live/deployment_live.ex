defmodule HomelabWeb.DeploymentLive do
  use HomelabWeb, :live_view

  alias Homelab.Deployments
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Readiness
  alias Homelab.Deployments.VolumeSpec
  alias Homelab.Catalog.ImageRef
  alias Homelab.Catalog.Tags
  alias Homelab.Backups
  alias Homelab.Services.BackupScheduler

  @log_poll_interval 3_000

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Deployment")
      |> assign(:deployment, nil)
      |> assign(:readiness, [])
      |> assign(:active_tab, "overview")
      |> assign(:logs, "")
      |> assign(:logs_loading, false)
      |> assign(:follow_logs, false)
      |> assign(:log_timer, nil)
      |> assign(:env_edit_mode, false)
      |> assign(:env_form, nil)
      |> assign(:env_rows, [])
      |> assign(:settings_edit_mode, false)
      |> assign(:settings_domain, "")
      |> assign(:settings_access, "proxy")
      |> assign(:settings_auth, "public")
      |> assign(:settings_ports, [])
      |> assign(:settings_routes, [])
      |> assign(:volumes_edit_mode, false)
      |> assign(:volumes_rows, [])
      |> assign(:settings_memory_mb, "")
      |> assign(:settings_cpu_shares, "")
      |> assign(:settings_gpu_vendor, "")
      |> assign(:settings_gpu_count, "")
      |> assign(:settings_gpu_devices, "")
      |> assign(:settings_gpu_kind, "")
      |> assign(:gpu_advertised_kinds, [])
      |> assign(:settings_health_path, "")
      |> assign(:settings_sticky, false)
      |> assign(:runtime_edit_mode, false)
      |> assign(:runtime_restart_policy, "on-failure")
      |> assign(:runtime_replicas, "1")
      # "inherit" | "custom" per list field. An empty custom list is a real value ([],
      # "run nothing"), which a blank textarea alone could not distinguish from inherit.
      |> assign(:runtime_command_mode, "inherit")
      |> assign(:runtime_command, "")
      |> assign(:runtime_entrypoint_mode, "inherit")
      |> assign(:runtime_entrypoint, "")
      |> assign(:runtime_aliases_mode, "inherit")
      |> assign(:runtime_aliases, "")
      |> assign(:version_edit_mode, false)
      |> assign(:version_image, "")
      # :idle | :loading | {:ok, [TagInfo]} | {:error, reason}. A registry that cannot
      # list tags is not an error state — the free-text field is the real control.
      |> assign(:available_tags, :idle)
      |> assign(:resource_stats, nil)
      |> assign(:traffic_stats, nil)
      |> assign(:tenants, [])
      |> assign(:siblings, [])
      |> assign(:releases, [])
      |> assign(:driving_release, nil)
      |> assign(:tls, :idle)

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
      |> assign_releases()
      |> assign_readiness()
      |> probe_tls()

    socket =
      if connected?(socket) do
        Phoenix.PubSub.subscribe(Homelab.PubSub, "metrics:update")

        Phoenix.PubSub.subscribe(
          Homelab.PubSub,
          Homelab.Deployments.Releases.topic(deployment.id)
        )

        # Companions have no release of their own — their state lives on the app's
        # release. Subscribe to that app's topic too so this page updates live.
        if socket.assigns.driving_release &&
             socket.assigns.driving_release.deployment_id != deployment.id do
          Phoenix.PubSub.subscribe(
            Homelab.PubSub,
            Homelab.Deployments.Releases.topic(socket.assigns.driving_release.deployment_id)
          )
        end

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

  # Loads the release history where this deployment is the app, plus the single
  # "driving" release that governs its lifecycle (the app's release even when
  # this deployment is only a companion in it).
  defp assign_releases(socket) do
    id = socket.assigns.deployment.id

    socket
    |> assign(:releases, Homelab.Deployments.Releases.list_releases_for_deployment(id))
    |> assign(:driving_release, Homelab.Deployments.Releases.driving_release(id))
  end

  @impl true
  def handle_info({ref, {:tls_probed, result}}, socket) do
    Process.demonitor(ref, [:flush])
    {:noreply, assign(socket, :tls, result)}
  end

  # A crashed probe must not wedge the card on "checking…".
  def handle_info({:DOWN, _ref, :process, _pid, _reason}, socket) do
    case socket.assigns.tls do
      :loading -> {:noreply, assign(socket, :tls, {:error, :probe_crashed})}
      _ -> {:noreply, socket}
    end
  end

  def handle_info({:metrics, _metrics}, socket) do
    {:noreply,
     socket
     |> load_resource_stats()
     |> load_traffic_stats()}
  end

  def handle_info({:deployment_status, deployment_id, _new_status}, socket) do
    if socket.assigns.deployment && socket.assigns.deployment.id == deployment_id do
      deployment = Deployments.get_deployment!(deployment_id)
      {:noreply, socket |> assign(:deployment, deployment) |> assign_readiness()}
    else
      {:noreply, socket}
    end
  end

  def handle_info({:release_updated, _release_deployment_id}, socket) do
    # We only subscribe to topics for this deployment and its driving release, so
    # any release update we receive is relevant — refresh the deployment row, the
    # release history, and the driving release together.
    if socket.assigns.deployment do
      deployment = Deployments.get_deployment!(socket.assigns.deployment.id)

      {:noreply,
       socket
       |> assign(:deployment, deployment)
       |> assign_releases()
       |> assign_readiness()}
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
  def handle_async(:available_tags, {:ok, result}, socket) do
    {:noreply, assign(socket, :available_tags, result)}
  end

  # A registry that crashes the fetch must not wedge the picker on "loading…" — the
  # free-text field beside it still works.
  def handle_async(:available_tags, {:exit, reason}, socket) do
    {:noreply, assign(socket, :available_tags, {:error, {:exit, reason}})}
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

    {:noreply,
     socket
     |> assign(:env_edit_mode, true)
     |> assign(:env_form, to_form(%{}))
     |> assign(:env_rows, env_rows(merged_env(deployment)))}
  end

  def handle_event("cancel_env_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_edit_mode, false)
     |> assign(:env_form, nil)
     |> assign(:env_rows, [])}
  end

  # Keep the rows in assigns as the user types, so add/remove don't discard edits.
  def handle_event("env_change", %{"env" => env}, socket) do
    {:noreply, assign(socket, :env_rows, rows_from_params(env))}
  end

  def handle_event("env_change", _params, socket), do: {:noreply, socket}

  def handle_event("add_env_var", _params, socket) do
    rows = socket.assigns.env_rows ++ [%{"key" => "", "value" => ""}]
    {:noreply, assign(socket, :env_rows, rows)}
  end

  def handle_event("remove_env_var", %{"index" => idx}, socket) do
    rows = List.delete_at(socket.assigns.env_rows, String.to_integer(idx))
    {:noreply, assign(socket, :env_rows, rows)}
  end

  def handle_event("save_env", params, socket) do
    deployment = socket.assigns.deployment

    env_overrides =
      params["env"]
      |> rows_from_params()
      |> Enum.reject(fn row -> String.trim(row["key"] || "") == "" end)
      |> Map.new(fn row -> {String.trim(row["key"]), row["value"] || ""} end)

    case apply_config(deployment, %{env_overrides: env_overrides}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> assign_readiness()
         |> assign(:env_edit_mode, false)
         |> assign(:env_form, nil)
         |> assign(:env_rows, [])
         |> put_flash(:info, "Environment updated — recreating the container.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # --- Version ---
  #
  # A separate card and a separate form from the rest of Settings, deliberately. Every
  # other field here is a config tweak; changing the image is the one action that can
  # replace the software the operator's data is sitting under.

  def handle_event("start_version_edit", _params, socket) do
    deployment = socket.assigns.deployment

    {:noreply,
     socket
     |> assign(:version_edit_mode, true)
     |> assign(:version_image, Access.effective_image(deployment))
     |> load_available_tags()}
  end

  def handle_event("cancel_version_edit", _params, socket) do
    {:noreply, assign(socket, version_edit_mode: false, available_tags: :idle)}
  end

  def handle_event("version_changed", %{"version" => %{"image" => image}}, socket) do
    {:noreply, assign(socket, :version_image, image)}
  end

  # Picking from the tag list fills the text field rather than saving: the operator
  # still confirms, and can still hand-edit what the picker produced.
  def handle_event("select_tag", %{"tag" => tag}, socket) do
    case ImageRef.with_tag(socket.assigns.version_image, tag) do
      {:ok, image} -> {:noreply, assign(socket, :version_image, image)}
      {:error, :invalid} -> {:noreply, socket}
    end
  end

  def handle_event("save_version", %{"version" => %{"image" => image}}, socket) do
    deployment = socket.assigns.deployment
    image = String.trim(image)

    # Typing the catalog's own image back in means "follow the catalog", not "pin to
    # what the catalog happens to say today".
    override = if image == "" or image == deployment.app_template.image, do: nil, else: image

    apply_version(socket, override)
  end

  def handle_event("reset_version", _params, socket) do
    apply_version(socket, nil)
  end

  # --- Runtime (restart policy / replicas / command / entrypoint / aliases) ---

  def handle_event("start_runtime_edit", _params, socket) do
    d = socket.assigns.deployment

    {:noreply,
     socket
     |> assign(:runtime_edit_mode, true)
     |> assign(:runtime_restart_policy, Access.effective_restart_policy(d))
     |> assign(:runtime_replicas, to_string(Access.effective_replicas(d)))
     |> assign_list_field(:command, d.command_override)
     |> assign_list_field(:entrypoint, d.entrypoint_override)
     |> assign_list_field(:aliases, d.network_aliases_override)}
  end

  def handle_event("cancel_runtime_edit", _params, socket) do
    {:noreply, assign(socket, :runtime_edit_mode, false)}
  end

  def handle_event("runtime_changed", %{"runtime" => runtime}, socket) do
    {:noreply,
     socket
     |> assign(:runtime_restart_policy, runtime["restart_policy"])
     |> assign(:runtime_replicas, runtime["replicas"])
     |> assign(:runtime_command_mode, runtime["command_mode"])
     |> assign(:runtime_command, runtime["command"])
     |> assign(:runtime_entrypoint_mode, runtime["entrypoint_mode"])
     |> assign(:runtime_entrypoint, runtime["entrypoint"])
     |> assign(:runtime_aliases_mode, runtime["aliases_mode"])
     |> assign(:runtime_aliases, runtime["aliases"])}
  end

  def handle_event("save_runtime", %{"runtime" => runtime}, socket) do
    deployment = socket.assigns.deployment

    attrs = %{
      restart_policy_override: blank_to_nil(runtime["restart_policy"]),
      replicas_override: parse_replicas(runtime["replicas"]),
      command_override: parse_list_field(runtime["command_mode"], runtime["command"]),
      entrypoint_override: parse_list_field(runtime["entrypoint_mode"], runtime["entrypoint"]),
      network_aliases_override: parse_list_field(runtime["aliases_mode"], runtime["aliases"])
    }

    case apply_config(deployment, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> assign_readiness()
         |> assign(:runtime_edit_mode, false)
         |> put_flash(:info, "Runtime settings saved — recreating the container.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # --- Settings (domain / exposure / ports) ---

  def handle_event("start_settings_edit", _params, socket) do
    deployment = socket.assigns.deployment
    exposure = Access.effective_exposure(deployment)
    limits = Access.effective_resource_limits(deployment)
    health = Access.effective_health_check(deployment)

    {:noreply,
     socket
     |> assign(:settings_edit_mode, true)
     |> assign(:settings_domain, deployment.domain || "")
     |> assign(:settings_access, Access.access_of(exposure))
     |> assign(:settings_auth, Access.auth_of(exposure))
     |> assign(:settings_ports, editable_ports(Access.effective_ports(deployment)))
     |> assign(:settings_routes, editable_routes(deployment.extra_routes))
     |> assign(:settings_memory_mb, to_string(limits["memory_mb"] || ""))
     |> assign(:settings_cpu_shares, to_string(limits["cpu_shares"] || ""))
     |> assign_gpu_settings(limits)
     |> assign(:settings_health_path, health["path"] || "")
     |> assign(:settings_sticky, (deployment.proxy_options || %{})["sticky"] == true)}
  end

  def handle_event("cancel_settings_edit", _params, socket) do
    {:noreply, assign(socket, :settings_edit_mode, false)}
  end

  # Keep the assigns in sync as the user types so add/remove-port don't drop edits.
  def handle_event("settings_changed", %{"settings" => settings}, socket) do
    {:noreply,
     socket
     |> assign(:settings_domain, settings["domain"] || socket.assigns.settings_domain)
     |> assign(:settings_access, settings["access"] || socket.assigns.settings_access)
     |> assign(:settings_auth, settings["auth"] || socket.assigns.settings_auth)
     |> assign(:settings_ports, ports_from_params(settings["ports"]))
     |> assign(:settings_routes, routes_from_params(settings["routes"]))
     |> assign(:settings_sticky, settings["sticky"] == "true")
     |> assign(:settings_memory_mb, settings["memory_mb"] || socket.assigns.settings_memory_mb)
     |> assign(:settings_cpu_shares, settings["cpu_shares"] || socket.assigns.settings_cpu_shares)
     # Vendor drives whether the rest of the GPU fields are even rendered, so it has to
     # round-trip on every change or picking NVIDIA would collapse the form again.
     |> assign(:settings_gpu_vendor, settings["gpu_vendor"] || socket.assigns.settings_gpu_vendor)
     |> assign(:settings_gpu_count, settings["gpu_count"] || socket.assigns.settings_gpu_count)
     |> assign(
       :settings_gpu_devices,
       settings["gpu_devices"] || socket.assigns.settings_gpu_devices
     )
     |> assign(:settings_gpu_kind, settings["gpu_kind"] || socket.assigns.settings_gpu_kind)
     |> assign(
       :settings_health_path,
       settings["health_path"] || socket.assigns.settings_health_path
     )}
  end

  def handle_event("recheck_tls", _params, socket) do
    {:noreply, probe_tls(socket)}
  end

  def handle_event("settings_add_port", _params, socket) do
    blank = %{
      "internal" => "",
      "external" => "",
      "role" => "other",
      "description" => "",
      "optional" => false
    }

    {:noreply, assign(socket, :settings_ports, socket.assigns.settings_ports ++ [blank])}
  end

  def handle_event("settings_remove_port", %{"index" => idx}, socket) do
    ports = List.delete_at(socket.assigns.settings_ports, String.to_integer(idx))
    {:noreply, assign(socket, :settings_ports, ports)}
  end

  def handle_event("start_volumes_edit", _params, socket) do
    rows = volume_rows(Access.effective_volumes(socket.assigns.deployment))

    {:noreply,
     socket
     |> assign(:volumes_edit_mode, true)
     |> assign(:volumes_rows, rows)}
  end

  def handle_event("cancel_volumes_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:volumes_edit_mode, false)
     |> assign(:volumes_rows, [])}
  end

  # Keep rows in assigns as the user types, so add/remove don't discard edits.
  def handle_event("volumes_changed", %{"volumes" => volumes}, socket) do
    {:noreply, assign(socket, :volumes_rows, volume_rows_from_params(volumes))}
  end

  def handle_event("volumes_changed", _params, socket), do: {:noreply, socket}

  def handle_event("add_volume", _params, socket) do
    blank = %{"container_path" => "", "description" => ""}
    {:noreply, assign(socket, :volumes_rows, socket.assigns.volumes_rows ++ [blank])}
  end

  def handle_event("remove_volume", %{"index" => idx}, socket) do
    rows = List.delete_at(socket.assigns.volumes_rows, String.to_integer(idx))
    {:noreply, assign(socket, :volumes_rows, rows)}
  end

  def handle_event("save_volumes", params, socket) do
    deployment = socket.assigns.deployment

    # `source` is preserved for a MANAGED volume too, not just a bind: adoption names the
    # volume it moved the data into (PermanentHome), and dropping that name here would
    # make SpecBuilder derive a synthetic one -- mounting an empty volume and orphaning
    # the adopted data. A blank source is the only one that gets derived.
    volumes = VolumeSpec.parse(params["volumes"])

    case apply_config(deployment, %{volumes_override: volumes}) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> assign_readiness()
         |> assign(:volumes_edit_mode, false)
         |> assign(:volumes_rows, [])
         |> put_flash(:info, "Volumes updated — recreating the container.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("settings_add_route", _params, socket) do
    blank = %{"path_prefix" => "", "port" => ""}
    {:noreply, assign(socket, :settings_routes, socket.assigns.settings_routes ++ [blank])}
  end

  def handle_event("settings_remove_route", %{"index" => idx}, socket) do
    routes = List.delete_at(socket.assigns.settings_routes, String.to_integer(idx))
    {:noreply, assign(socket, :settings_routes, routes)}
  end

  def handle_event("save_settings", %{"settings" => settings}, socket) do
    deployment = socket.assigns.deployment
    access = settings["access"] || socket.assigns.settings_access
    auth = settings["auth"] || socket.assigns.settings_auth

    exposure = Access.exposure_for(access, auth)
    # Domain only matters for proxy access; in Host mode every listed port binds.
    domain = if access == "proxy", do: blank_to_nil(settings["domain"]), else: nil

    # Proxy mode used to hard-code `[]` here, which is NOT "inherit the template" —
    # `Access.effective_ports/1` only inherits on nil, so an empty override won, and
    # `primary_port([])` falls back to "80". Merely opening Settings and saving
    # silently repointed the reverse proxy at port 80. Parse the form in every mode,
    # publish to the host only in host mode, and treat "no ports" as inherit.
    ports =
      settings["ports"]
      |> Homelab.Deployments.ConfigForm.parse_ports()
      |> Enum.map(&Map.put(&1, "published", access == "host"))

    attrs = %{
      domain: domain,
      exposure_mode_override: exposure,
      ports_override: if(ports == [], do: nil, else: ports),
      routed_port: parse_routed_port(settings["routed_port"]),
      # Only a proxied app has paths to route; in host mode Traefik is not in the way.
      extra_routes: if(access == "proxy", do: parse_routes(settings["routes"]), else: []),
      proxy_options: proxy_options(settings, access),
      resource_limits_override: limits_override(settings),
      health_check_override: health_override(deployment, settings)
    }

    case apply_config(deployment, attrs) do
      {:ok, updated} ->
        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> assign_readiness()
         |> assign(:settings_edit_mode, false)
         |> put_flash(:info, "Settings saved — recreating the container.")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
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

  def handle_event("redeploy", _params, socket) do
    case Deployments.redeploy(socket.assigns.deployment) do
      {:ok, _release} ->
        {:noreply,
         socket
         |> assign_releases()
         |> put_flash(:info, "Re-running the deployment — watch the Releases tab.")}

      {:error, :release_active} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "A release is already in flight for this stack. Wait for it to finish before re-running."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Could not start a new release.")}
    end
  end

  def handle_event("delete", _params, socket) do
    case Deployments.destroy_deployment(socket.assigns.deployment) do
      {:ok, _} ->
        {:noreply,
         socket
         |> put_flash(:info, "Deployment deleted.")
         |> push_navigate(to: ~p"/")}

      {:error, {:undeploy_failed, _reason}} ->
        {:noreply,
         put_flash(
           socket,
           :error,
           "Could not remove the container, so the deployment was kept. Retry delete once Docker is reachable."
         )}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to delete deployment.")}
    end
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
      notification_count={@notification_count}
      notifications={@notifications}
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
              tab <- [
                "overview",
                "settings",
                "topology",
                "traffic",
                "logs",
                "environment",
                "volumes",
                "backups",
                "releases"
              ]
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
                :if={can_redeploy?(@driving_release)}
                type="button"
                phx-click="redeploy"
                data-confirm="Re-run the deployment steps for this stack from the start?"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
              >
                Re-run deploy
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
          <.tls_card tls={@tls} domain={@deployment.domain} />
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

          <%!-- Why the stack is stuck: a companion's failure lives on the app's
                release, so surface the failed step here even when this row has no
                error_message of its own. --%>
          <div
            :if={failed_step(@driving_release)}
            class="rounded-lg bg-error/10 border border-error/20 px-4 py-3 flex items-start gap-3"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 text-error flex-shrink-0 mt-0.5" />
            <div class="min-w-0">
              <p class="text-sm font-semibold text-error">
                Deploy stopped at "{failed_step(@driving_release).type
                |> to_string()
                |> String.replace("_", " ")}"
              </p>
              <p
                :if={failed_step(@driving_release).error_message}
                class="text-sm text-error/80 mt-0.5 font-mono break-words"
              >
                {failed_step(@driving_release).error_message}
              </p>
              <p class="text-xs text-error/60 mt-1">
                See the Releases tab for every step, or use "Re-run deploy" to try again.
              </p>
            </div>
          </div>

          <%!-- Production-readiness checklist: the bridge from iterating to prod --%>
          <div class="rounded-lg bg-base-100 p-4 border border-base-content/5">
            <div class="flex items-center justify-between mb-3">
              <h3 class="text-sm font-semibold text-base-content/70">Production readiness</h3>
              <span class="text-xs text-base-content/40">
                {Enum.count(@readiness, &(&1.status == :pass))} / {length(@readiness)} ready
              </span>
            </div>
            <ul class="space-y-2.5">
              <li
                :for={check <- Enum.sort_by(@readiness, &(&1.status == :pass))}
                class="flex items-start gap-3"
              >
                <.icon
                  name={
                    if(check.status == :pass,
                      do: "hero-check-circle-mini",
                      else: "hero-exclamation-circle-mini"
                    )
                  }
                  class={[
                    "size-4 mt-0.5 flex-shrink-0",
                    if(check.status == :pass, do: "text-success", else: "text-warning")
                  ]}
                />
                <div class="flex-1 min-w-0">
                  <p class="text-sm font-medium text-base-content">{check.title}</p>
                  <p class="text-xs text-base-content/40">{check.detail}</p>
                </div>
                <button
                  :if={check.status == :gap}
                  type="button"
                  phx-click="switch_tab"
                  phx-value-tab={check.fix_tab}
                  class="text-xs font-medium text-primary hover:text-primary/80 flex-shrink-0"
                >
                  Fix →
                </button>
              </li>
            </ul>
          </div>

          <div class="grid grid-cols-1 md:grid-cols-2 gap-4">
            <div class="rounded-lg bg-base-100 p-4 border border-base-content/5">
              <h3 class="text-sm font-semibold text-base-content/70 mb-4">Details</h3>
              <dl class="space-y-3 text-sm">
                <div>
                  <dt class="text-base-content/50 flex items-center justify-between gap-2">
                    <span>Image</span>
                    <%!-- The image used to be a dead end here: displayed, never editable,
                          with nothing to say where it could be changed. Matches the
                          readiness checklist's "Fix →" affordance. --%>
                    <button
                      type="button"
                      phx-click="switch_tab"
                      phx-value-tab="settings"
                      class="text-xs font-medium text-primary hover:text-primary/80 cursor-pointer"
                    >
                      Change →
                    </button>
                  </dt>
                  <dd class="font-mono text-base-content">
                    {Access.effective_image(@deployment)}
                    <span
                      :if={Access.image_overridden?(@deployment)}
                      class="ml-1 px-1.5 py-0.5 rounded text-[10px] font-sans font-medium bg-primary/10 text-primary"
                    >
                      Pinned
                    </span>
                  </dd>
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

        <%!-- Settings tab (domain / exposure / ports) --%>
        <div
          :if={@active_tab == "settings"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden mb-4"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Version</h3>
            <button
              :if={!@version_edit_mode}
              type="button"
              phx-click="start_version_edit"
              class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary/20 transition-colors"
            >
              Change
            </button>
          </div>
          <div class="p-4">
            <%= if @version_edit_mode do %>
              <.form
                for={%{}}
                id="version-form"
                phx-change="version_changed"
                phx-submit="save_version"
                class="space-y-4"
              >
                <div class="flex flex-col gap-1.5">
                  <label class="text-xs font-medium text-base-content/50">Image reference</label>
                  <input
                    type="text"
                    name="version[image]"
                    value={@version_image}
                    autocomplete="off"
                    placeholder="gitlab/gitlab-ce:17.0.0"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                  <p class="text-xs text-base-content/40">
                    The catalog default is <span class="font-mono">{@deployment.app_template.image}</span>.
                  </p>
                </div>

                <div :if={@available_tags != :idle} class="flex flex-col gap-1.5">
                  <label class="text-xs font-medium text-base-content/50">
                    Available versions
                  </label>
                  <p :if={@available_tags == :loading} class="text-xs text-base-content/40">
                    Asking the registry…
                  </p>
                  <p
                    :if={match?({:error, _}, @available_tags)}
                    class="text-xs text-base-content/40"
                  >
                    The registry did not answer — type a tag above instead.
                  </p>
                  <div :if={match?({:ok, _}, @available_tags)} class="flex flex-wrap gap-1.5">
                    <button
                      :for={tag <- elem(@available_tags, 1)}
                      type="button"
                      phx-click="select_tag"
                      phx-value-tag={tag.tag}
                      class="px-2 py-1 rounded-md bg-base-200 text-xs font-mono text-base-content/70 hover:bg-primary/10 hover:text-primary transition-colors cursor-pointer"
                      title={tag.last_updated && "Updated #{tag.last_updated}"}
                    >
                      {tag.tag}
                    </button>
                  </div>
                </div>

                <%!-- A version change is not a port tweak. Say what it costs BEFORE the
                      operator commits, because the expensive half of this mistake
                      (skipping an app's required intermediate versions) is not
                      recoverable from this screen. --%>
                <div class="rounded-lg bg-warning/5 border border-warning/20 p-3 space-y-1">
                  <p class="text-xs font-medium text-warning">
                    This recreates the container.
                  </p>
                  <p class="text-xs text-base-content/60">
                    The app is briefly unavailable, and its data is left in place. Check the
                    app's own upgrade notes first — some (GitLab, Nextcloud, Mastodon) must be
                    upgraded one version at a time, and skipping releases can leave the install
                    unrecoverable.
                  </p>
                </div>

                <div class="flex items-center gap-2">
                  <button
                    type="submit"
                    class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
                  >
                    Save &amp; recreate
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_version_edit"
                    class="px-3 py-1.5 rounded-lg bg-base-200 text-base-content/70 text-sm font-medium hover:bg-base-300 transition-colors"
                  >
                    Cancel
                  </button>
                  <button
                    :if={Access.image_overridden?(@deployment)}
                    type="button"
                    phx-click="reset_version"
                    data-confirm="Reset to the catalog default and recreate the container?"
                    class="ml-auto text-xs text-base-content/50 hover:text-base-content transition-colors cursor-pointer"
                  >
                    Reset to catalog default
                  </button>
                </div>
              </.form>
            <% else %>
              <dl class="space-y-3 text-sm">
                <div>
                  <dt class="text-base-content/50 text-xs">Running</dt>
                  <dd class="font-mono text-base-content flex items-center gap-2">
                    {Access.effective_image(@deployment)}
                    <span
                      :if={Access.image_overridden?(@deployment)}
                      class="px-1.5 py-0.5 rounded text-[10px] font-sans font-medium bg-primary/10 text-primary"
                    >
                      Pinned
                    </span>
                    <span
                      :if={!Access.image_overridden?(@deployment)}
                      class="px-1.5 py-0.5 rounded text-[10px] font-sans font-medium bg-base-200 text-base-content/50"
                    >
                      Catalog default
                    </span>
                  </dd>
                </div>
                <div :if={Access.image_overridden?(@deployment)}>
                  <dt class="text-base-content/50 text-xs">Catalog default</dt>
                  <dd class="font-mono text-base-content/50 text-xs">
                    {@deployment.app_template.image}
                  </dd>
                </div>
              </dl>
            <% end %>
          </div>
        </div>

        <div
          :if={@active_tab == "settings"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden mb-4"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Runtime</h3>
            <button
              :if={!@runtime_edit_mode}
              type="button"
              phx-click="start_runtime_edit"
              class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary/20 transition-colors"
            >
              Edit
            </button>
          </div>
          <div class="p-4">
            <%= if @runtime_edit_mode do %>
              <.form
                for={%{}}
                id="runtime-form"
                phx-change="runtime_changed"
                phx-submit="save_runtime"
                class="space-y-5"
              >
                <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
                  <div class="flex flex-col gap-1.5">
                    <label class="text-xs font-medium text-base-content/50">Restart policy</label>
                    <select
                      name="runtime[restart_policy]"
                      class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
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
                        selected={@runtime_restart_policy == value}
                      >
                        {label}
                      </option>
                    </select>
                  </div>

                  <div class="flex flex-col gap-1.5">
                    <label class="text-xs font-medium text-base-content/50">Replicas</label>
                    <input
                      type="number"
                      min="1"
                      name="runtime[replicas]"
                      value={@runtime_replicas}
                      disabled={!swarm?()}
                      class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50 disabled:opacity-60"
                    />
                    <p class="text-xs text-base-content/40">
                      <%= if swarm?() do %>
                        Not available with host ports or host networking — every task would
                        bind the same port.
                      <% else %>
                        Docker Engine runs a single container; scaling needs Swarm.
                      <% end %>
                    </p>
                  </div>
                </div>

                <.runtime_list_field
                  name="command"
                  label="Command"
                  hint="What the container runs. One argument per line."
                  mode={@runtime_command_mode}
                  value={@runtime_command}
                />
                <.runtime_list_field
                  name="entrypoint"
                  label="Entrypoint"
                  hint="Overrides the image's own entrypoint. One argument per line; custom-and-empty clears it."
                  mode={@runtime_entrypoint_mode}
                  value={@runtime_entrypoint}
                />
                <.runtime_list_field
                  name="aliases"
                  label="Network aliases"
                  hint="Extra names siblings can reach this container by, one per line. Ignored on the host network."
                  mode={@runtime_aliases_mode}
                  value={@runtime_aliases}
                />

                <div class="flex items-center gap-2">
                  <button
                    type="submit"
                    class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
                  >
                    Save &amp; recreate
                  </button>
                  <button
                    type="button"
                    phx-click="cancel_runtime_edit"
                    class="px-3 py-1.5 rounded-lg bg-base-200 text-base-content/70 text-sm font-medium hover:bg-base-300 transition-colors"
                  >
                    Cancel
                  </button>
                </div>
              </.form>
            <% else %>
              <dl class="grid grid-cols-1 sm:grid-cols-2 gap-3 text-sm">
                <div>
                  <dt class="text-base-content/50 text-xs">Restart policy</dt>
                  <dd class="text-base-content">
                    {Access.effective_restart_policy(@deployment)}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50 text-xs">Replicas</dt>
                  <dd class="text-base-content">{Access.effective_replicas(@deployment)}</dd>
                </div>
                <div>
                  <dt class="text-base-content/50 text-xs">Command</dt>
                  <dd class="font-mono text-xs text-base-content">
                    {format_list(Access.effective_command(@deployment))}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50 text-xs">Entrypoint</dt>
                  <dd class="font-mono text-xs text-base-content">
                    {format_list(Access.effective_entrypoint(@deployment))}
                  </dd>
                </div>
                <div>
                  <dt class="text-base-content/50 text-xs">Network aliases</dt>
                  <dd class="font-mono text-xs text-base-content">
                    {format_list(Access.effective_network_aliases(@deployment))}
                  </dd>
                </div>
              </dl>
            <% end %>
          </div>
        </div>

        <div
          :if={@active_tab == "settings"}
          class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden"
        >
          <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
            <h3 class="text-sm font-semibold text-base-content">Network &amp; ports</h3>
            <button
              :if={!@settings_edit_mode}
              type="button"
              phx-click="start_settings_edit"
              class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary/20 transition-colors"
            >
              Edit
            </button>
          </div>
          <div class="p-4">
            <%= if @settings_edit_mode do %>
              <.form
                for={%{}}
                id="settings-form"
                phx-change="settings_changed"
                phx-submit="save_settings"
                class="space-y-5"
              >
                <div class="flex flex-col gap-1.5">
                  <label class="text-xs font-medium text-base-content/50">Access</label>
                  <div class="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-2">
                    <label
                      :for={{value, title, desc} <- Access.access_choices()}
                      class={[
                        "flex flex-col gap-0.5 rounded-lg border p-2.5 cursor-pointer transition-colors",
                        if(@settings_access == value,
                          do: "border-primary bg-primary/5",
                          else: "border-base-content/10 hover:border-base-content/20"
                        )
                      ]}
                    >
                      <input
                        type="radio"
                        name="settings[access]"
                        value={value}
                        checked={@settings_access == value}
                        class="sr-only"
                      />
                      <span class="text-xs font-semibold text-base-content">{title}</span>
                      <span class="text-[10px] text-base-content/40 leading-snug">{desc}</span>
                    </label>
                  </div>
                </div>

                <div :if={@settings_access == "proxy"} class="space-y-4 rounded-lg bg-base-200/40 p-3">
                  <div class="flex flex-col gap-1.5">
                    <label class="text-xs font-medium text-base-content/50">Authentication</label>
                    <div class="grid grid-cols-3 gap-2">
                      <label
                        :for={{value, title, desc} <- Access.auth_choices()}
                        class={[
                          "flex flex-col gap-0.5 rounded-lg border p-2 cursor-pointer transition-colors",
                          if(@settings_auth == value,
                            do: "border-primary bg-primary/5",
                            else: "border-base-content/10 hover:border-base-content/20"
                          )
                        ]}
                      >
                        <input
                          type="radio"
                          name="settings[auth]"
                          value={value}
                          checked={@settings_auth == value}
                          class="sr-only"
                        />
                        <span class="text-xs font-semibold text-base-content">{title}</span>
                        <span class="text-[10px] text-base-content/40 leading-snug">{desc}</span>
                      </label>
                    </div>
                  </div>
                  <div class="flex flex-col gap-1">
                    <label class="text-xs font-medium text-base-content/50">Domain</label>
                    <input
                      type="text"
                      name="settings[domain]"
                      value={@settings_domain}
                      placeholder={"#{@deployment.app_template.slug}.yourdomain.com"}
                      class="w-full rounded-lg bg-base-100 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                    />
                    <p class="text-[10px] text-base-content/40">
                      Add a domain to go live; until then the app isn't reachable externally.
                    </p>
                  </div>

                  <div class="flex flex-col gap-2">
                    <div class="flex items-center justify-between">
                      <label class="text-xs font-medium text-base-content/50">
                        App port — where the proxy sends traffic
                      </label>
                      <button
                        type="button"
                        phx-click="settings_add_port"
                        class="text-xs text-primary hover:text-primary/80"
                      >
                        + Add port
                      </button>
                    </div>
                    <p :if={@settings_ports == []} class="text-[11px] text-warning">
                      No port set — the proxy will fall back to port 80, which is almost
                      certainly not what the app listens on.
                    </p>
                    <div
                      :for={{port, idx} <- Enum.with_index(@settings_ports)}
                      class="flex items-center gap-2"
                    >
                      <label class="flex items-center gap-1.5 cursor-pointer">
                        <input
                          type="radio"
                          name="settings[routed_port]"
                          value={port["internal"]}
                          checked={
                            checked_routed_port(@deployment, @settings_ports) ==
                              to_string(port["internal"])
                          }
                          class="radio radio-xs radio-primary"
                        />
                        <span class="text-[10px] text-base-content/40 w-10">route</span>
                      </label>
                      <input
                        type="text"
                        name={"settings[ports][#{idx}][internal]"}
                        value={port["internal"]}
                        placeholder="container port"
                        class="w-28 rounded-lg bg-base-100 border-0 text-sm py-1.5 px-2"
                      />
                      <input
                        type="hidden"
                        name={"settings[ports][#{idx}][role]"}
                        value={port["role"]}
                      />
                      <input
                        type="text"
                        name={"settings[ports][#{idx}][description]"}
                        value={port["description"]}
                        placeholder="what it's for (optional)"
                        class="flex-1 rounded-lg bg-base-100 border-0 text-xs py-1.5 px-2 text-base-content/60"
                      />
                      <button
                        type="button"
                        phx-click="settings_remove_port"
                        phx-value-index={idx}
                        class="text-base-content/30 hover:text-error"
                      >
                        <.icon name="hero-x-mark" class="size-4" />
                      </button>
                    </div>
                    <p class="text-[10px] text-base-content/40">
                      The selected port is the one Traefik forwards to inside the container.
                      Nothing is published to the host.
                    </p>
                  </div>

                  <div class="space-y-2 rounded-lg bg-base-200/40 p-3">
                    <div class="flex items-center justify-between">
                      <span class="text-xs font-medium text-base-content">Extra path routes</span>
                      <button
                        type="button"
                        phx-click="settings_add_route"
                        class="text-[10px] text-primary hover:underline cursor-pointer"
                      >
                        + Add route
                      </button>
                    </div>
                    <p class="text-[10px] text-base-content/40 leading-snug">
                      Send one path to a <em>different</em>
                      port in the same container. An app that serves
                      a second protocol from a second port needs this — Laravel Reverb answers
                      websockets on 6001 while the app itself is on 8000, so <code>/app</code>
                      has to reach 6001 or every handshake lands on the HTTP server.
                    </p>

                    <div
                      :for={{route, idx} <- Enum.with_index(@settings_routes)}
                      class="flex items-center gap-2"
                    >
                      <input
                        type="text"
                        name={"settings[routes][#{idx}][path_prefix]"}
                        value={route["path_prefix"]}
                        placeholder="/app"
                        class="flex-1 rounded-lg bg-base-200 border-0 text-xs font-mono py-1.5 px-2"
                      />
                      <span class="text-[10px] text-base-content/40">→</span>
                      <input
                        type="text"
                        inputmode="numeric"
                        name={"settings[routes][#{idx}][port]"}
                        value={route["port"]}
                        placeholder="6001"
                        class="w-24 rounded-lg bg-base-200 border-0 text-xs font-mono py-1.5 px-2"
                      />
                      <button
                        type="button"
                        phx-click="settings_remove_route"
                        phx-value-index={idx}
                        class="p-1.5 text-base-content/40 hover:text-error cursor-pointer"
                        aria-label={"Remove route #{route["path_prefix"]}"}
                      >
                        <.icon name="hero-trash" class="size-3.5" />
                      </button>
                    </div>
                  </div>

                  <label class="flex items-start gap-2 cursor-pointer">
                    <input type="hidden" name="settings[sticky]" value="false" />
                    <input
                      type="checkbox"
                      name="settings[sticky]"
                      value="true"
                      checked={@settings_sticky}
                      class="checkbox checkbox-xs checkbox-primary mt-0.5"
                    />
                    <span class="flex flex-col gap-0.5">
                      <span class="text-xs font-medium text-base-content">Sticky sessions</span>
                      <span class="text-[10px] text-base-content/40 leading-snug">
                        Pins each client to one replica. Websockets and LiveView are proxied
                        automatically, but with more than one replica a reconnect can land on a
                        different container and drop the session.
                      </span>
                    </span>
                  </label>
                </div>

                <div :if={@settings_access == "host"} class="space-y-2 rounded-lg bg-base-200/40 p-3">
                  <div class="flex items-center justify-between">
                    <label class="text-xs font-medium text-base-content/50">
                      Container → host ports
                    </label>
                    <button
                      type="button"
                      phx-click="settings_add_port"
                      class="text-xs text-primary hover:text-primary/80"
                    >
                      + Add port
                    </button>
                  </div>
                  <p :if={@settings_ports == []} class="text-[11px] text-base-content/30">
                    No ports yet — add a container→host mapping.
                  </p>
                  <div
                    :for={{port, idx} <- Enum.with_index(@settings_ports)}
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name={"settings[ports][#{idx}][internal]"}
                      value={port["internal"]}
                      placeholder="container"
                      class="w-24 rounded-lg bg-base-100 border-0 text-sm py-1.5 px-2"
                    />
                    <span class="text-base-content/30">→</span>
                    <input
                      type="text"
                      name={"settings[ports][#{idx}][external]"}
                      value={port["external"]}
                      placeholder="host"
                      class="w-24 rounded-lg bg-base-100 border-0 text-sm py-1.5 px-2"
                    />
                    <button
                      type="button"
                      phx-click="settings_remove_port"
                      phx-value-index={idx}
                      class="text-base-content/30 hover:text-error ml-auto"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </div>

                <%!-- Host network: the container is IN the host's namespace, so there is no
                   mapping to edit. The ports are still worth keeping — they drive the
                   healthcheck — and rendering them keeps `ports_override` from being
                   silently dropped on save, which would fall back to the template. --%>
                <div
                  :if={@settings_access == "host_network"}
                  class="space-y-2 rounded-lg bg-base-200/40 p-3"
                >
                  <div class="flex items-center justify-between">
                    <label class="text-xs font-medium text-base-content/50">
                      Ports it listens on
                    </label>
                    <button
                      type="button"
                      phx-click="settings_add_port"
                      class="text-xs text-primary hover:text-primary/80"
                    >
                      + Add port
                    </button>
                  </div>
                  <p class="text-[11px] text-base-content/40">
                    On the host's network these are the host's ports — nothing is mapped, so
                    there is no separate host port to choose. A port already in use on the host
                    will keep the container from starting.
                  </p>
                  <div
                    :for={{port, idx} <- Enum.with_index(@settings_ports)}
                    class="flex items-center gap-2"
                  >
                    <input
                      type="text"
                      name={"settings[ports][#{idx}][internal]"}
                      value={port["internal"]}
                      placeholder="port"
                      class="w-24 rounded-lg bg-base-100 border-0 text-sm py-1.5 px-2"
                    />
                    <button
                      type="button"
                      phx-click="settings_remove_port"
                      phx-value-index={idx}
                      class="text-base-content/30 hover:text-error ml-auto"
                    >
                      <.icon name="hero-x-mark" class="size-4" />
                    </button>
                  </div>
                </div>

                <p
                  :if={@settings_access == "internal"}
                  class="text-[11px] text-base-content/40 rounded-lg bg-base-200/40 p-3"
                >
                  Internal only — reachable on the container network, with no host port or public route.
                </p>

                <%!-- Resilience: resource limits + healthcheck (closes the readiness gate) --%>
                <div class="space-y-3 border-t border-base-content/5 pt-4">
                  <label class="text-xs font-medium text-base-content/50">Resilience</label>
                  <div class="grid grid-cols-2 gap-3">
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">Memory (MB)</label>
                      <input
                        type="number"
                        min="1"
                        name="settings[memory_mb]"
                        value={@settings_memory_mb}
                        placeholder="256"
                        class="w-full rounded-lg bg-base-200 border-0 text-sm py-1.5 px-2.5"
                      />
                    </div>
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">CPU shares</label>
                      <input
                        type="number"
                        min="1"
                        name="settings[cpu_shares]"
                        value={@settings_cpu_shares}
                        placeholder="512"
                        class="w-full rounded-lg bg-base-200 border-0 text-sm py-1.5 px-2.5"
                      />
                    </div>
                  </div>

                  <%!-- GPU. A reservation, not a limit: it decides WHICH NODE the task
                        lands on, and whether a device is in the container at all. --%>
                  <div class="grid grid-cols-2 gap-3">
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">GPU</label>
                      <select
                        name="settings[gpu_vendor]"
                        class="w-full rounded-lg bg-base-200 border-0 text-sm py-1.5 px-2.5"
                      >
                        <option value="" selected={@settings_gpu_vendor in [nil, ""]}>None</option>
                        <option value="nvidia" selected={@settings_gpu_vendor == "nvidia"}>
                          NVIDIA
                        </option>
                        <option value="amd" selected={@settings_gpu_vendor == "amd"}>
                          AMD (ROCm)
                        </option>
                      </select>
                    </div>
                    <div :if={@settings_gpu_vendor in ["nvidia", "amd"]} class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">Devices</label>
                      <input
                        type="text"
                        name="settings[gpu_devices]"
                        value={@settings_gpu_devices}
                        placeholder="all"
                        class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono py-1.5 px-2.5"
                      />
                    </div>
                  </div>

                  <div :if={@settings_gpu_vendor in ["nvidia", "amd"]} class="grid grid-cols-2 gap-3">
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">GPUs to reserve</label>
                      <input
                        type="number"
                        min="1"
                        name="settings[gpu_count]"
                        value={@settings_gpu_count}
                        placeholder="1"
                        class="w-full rounded-lg bg-base-200 border-0 text-sm py-1.5 px-2.5"
                      />
                    </div>
                    <div class="flex flex-col gap-1">
                      <label class="text-[10px] text-base-content/40">
                        Swarm resource kind
                      </label>
                      <input
                        type="text"
                        name="settings[gpu_kind]"
                        value={@settings_gpu_kind}
                        list="gpu-kinds"
                        placeholder={Homelab.Deployments.GpuSpec.default_kind(@settings_gpu_vendor)}
                        class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono py-1.5 px-2.5"
                      />
                      <datalist id="gpu-kinds">
                        <option :for={kind <- @gpu_advertised_kinds} value={kind}></option>
                      </datalist>
                    </div>
                  </div>

                  <div
                    :if={@settings_gpu_vendor in ["nvidia", "amd"]}
                    class="rounded-lg bg-warning/10 border border-warning/20 px-3 py-2 space-y-1"
                  >
                    <p class="text-[11px] text-base-content/70 leading-snug">
                      <strong>Swarm cannot pass a device.</strong>
                      A GPU is reachable only as a generic resource the node declares in its
                      <code class="font-mono">daemon.json</code>
                      — the reservation decides which node the task lands on, and the vendor
                      runtime (set as that node's <code class="font-mono">default-runtime</code>)
                      is what actually puts the device in the container.
                    </p>
                    <p :if={@gpu_advertised_kinds == []} class="text-[11px] text-warning leading-snug">
                      No node in this swarm currently advertises a GPU. Deploying this would
                      leave the task pending forever, so it will be refused with the exact
                      <code class="font-mono">daemon.json</code>
                      change needed.
                    </p>
                    <p :if={@gpu_advertised_kinds != []} class="text-[11px] text-base-content/60">
                      Nodes advertise: {Enum.join(@gpu_advertised_kinds, ", ")}
                    </p>
                  </div>
                  <div class="flex flex-col gap-1">
                    <label class="text-[10px] text-base-content/40">Health check path</label>
                    <input
                      type="text"
                      name="settings[health_path]"
                      value={@settings_health_path}
                      placeholder="/health"
                      class="w-full rounded-lg bg-base-200 border-0 text-sm py-1.5 px-2.5"
                    />
                    <p class="text-[10px] text-base-content/40">
                      An HTTP path probed for readiness. Set memory, CPU, and a path to clear the resilience gate.
                    </p>
                  </div>
                </div>

                <div class="flex gap-2 pt-1">
                  <button
                    type="button"
                    phx-click="cancel_settings_edit"
                    class="px-3 py-1.5 rounded-lg text-sm text-base-content/70 hover:bg-base-200"
                  >
                    Cancel
                  </button>
                  <.button
                    type="submit"
                    label="Save and recreate"
                    data-confirm={"Recreate #{@deployment.app_template.name}? The app restarts briefly while the new configuration is applied."}
                    class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
                  />
                </div>
              </.form>
            <% else %>
              <% access = Access.access_of(Access.effective_exposure(@deployment)) %>
              <dl class="space-y-3 text-sm">
                <div class="flex justify-between gap-4">
                  <dt class="text-base-content/50">Access</dt>
                  <dd class="text-base-content">{settings_access_label(@deployment)}</dd>
                </div>
                <div :if={access == "proxy"} class="flex justify-between gap-4">
                  <dt class="text-base-content/50">Domain</dt>
                  <dd class="text-base-content font-mono">
                    {@deployment.domain || "— (add to go live)"}
                  </dd>
                </div>
                <div :if={access == "host"} class="flex justify-between gap-4">
                  <dt class="text-base-content/50">Host ports</dt>
                  <dd class="text-base-content font-mono text-right">
                    <%= case Access.effective_ports(@deployment) do %>
                      <% [] -> %>
                        —
                      <% ports -> %>
                        <span :for={p <- ports} class="block">
                          {p["internal"]} → {p["external"] || p["internal"]}
                        </span>
                    <% end %>
                  </dd>
                </div>
                <%!-- Host network: nothing is MAPPED, so these are shown as-is rather
                   than as `container → host` pairs, which would imply a rule exists. --%>
                <div :if={access == "host_network"} class="flex justify-between gap-4">
                  <dt class="text-base-content/50">Listening on host</dt>
                  <dd class="text-base-content font-mono text-right">
                    <%= case Access.effective_ports(@deployment) do %>
                      <% [] -> %>
                        —
                      <% ports -> %>
                        <span :for={p <- ports} class="block">{p["internal"]}</span>
                    <% end %>
                  </dd>
                </div>
              </dl>
            <% end %>
          </div>
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
              <.form
                for={@env_form}
                id="env-form"
                phx-change="env_change"
                phx-submit="save_env"
                class="space-y-3"
              >
                <div :for={{row, idx} <- Enum.with_index(@env_rows)} class="flex items-center gap-2">
                  <input
                    type="text"
                    name={"env[#{idx}][key]"}
                    value={row["key"]}
                    placeholder="VARIABLE"
                    class="w-2/5 rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                  <input
                    type={if secret_key?(row["key"]), do: "password", else: "text"}
                    name={"env[#{idx}][value]"}
                    value={row["value"]}
                    placeholder="value"
                    class="flex-1 rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                  <button
                    type="button"
                    phx-click="remove_env_var"
                    phx-value-index={idx}
                    class="p-2 text-base-content/40 hover:text-error cursor-pointer"
                    aria-label={"Remove #{row["key"]}"}
                  >
                    <.icon name="hero-trash" class="size-4" />
                  </button>
                </div>

                <button
                  type="button"
                  phx-click="add_env_var"
                  class="text-xs text-primary hover:underline cursor-pointer"
                >
                  + Add variable
                </button>

                <p class="text-[11px] text-base-content/40">
                  Saving recreates the container. A variable compiled into a frontend
                  bundle at build time (e.g. <code>VITE_*</code>) cannot be changed here.
                </p>

                <.button
                  type="submit"
                  label="Save"
                  class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
                />
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
          <div class="px-4 py-3 border-b border-base-content/5 flex items-center justify-between">
            <h3 class="text-sm font-semibold text-base-content">Volumes</h3>
            <button
              :if={!@volumes_edit_mode}
              type="button"
              phx-click="start_volumes_edit"
              class="text-xs text-primary hover:underline cursor-pointer"
            >
              Edit
            </button>
            <button
              :if={@volumes_edit_mode}
              type="button"
              phx-click="cancel_volumes_edit"
              class="text-xs text-base-content/50 hover:underline cursor-pointer"
            >
              Cancel
            </button>
          </div>
          <div class="p-4">
            <.form
              :if={@volumes_edit_mode}
              for={%{}}
              as={:volumes}
              id="volumes-form"
              phx-change="volumes_changed"
              phx-submit="save_volumes"
              class="space-y-3"
            >
              <div
                :for={{vol, idx} <- Enum.with_index(@volumes_rows)}
                class="flex items-center gap-2"
              >
                <select
                  name={"volumes[#{idx}][type]"}
                  class="w-32 rounded-lg bg-base-200 border-0 text-xs py-1.5 px-2"
                >
                  <option value="volume" selected={vol["type"] != "bind"}>Managed</option>
                  <option value="bind" selected={vol["type"] == "bind"}>Folder</option>
                </select>
                <input
                  :if={vol["type"] == "bind"}
                  type="text"
                  name={"volumes[#{idx}][source]"}
                  value={vol["source"]}
                  placeholder="/home/you/.homelab/app/data"
                  class="flex-1 rounded-lg bg-base-200 border-0 text-xs font-mono py-1.5 px-2"
                />
                <span :if={vol["type"] == "bind"} class="text-[10px] text-base-content/40">→</span>
                <input
                  type="text"
                  name={"volumes[#{idx}][container_path]"}
                  value={vol["container_path"]}
                  placeholder="/var/www/html/storage"
                  class="flex-1 rounded-lg bg-base-200 border-0 text-xs font-mono py-1.5 px-2"
                />
                <input
                  :if={vol["type"] != "bind"}
                  type="text"
                  name={"volumes[#{idx}][description]"}
                  value={vol["description"]}
                  placeholder="what it holds (optional)"
                  class="w-40 rounded-lg bg-base-200 border-0 text-xs py-1.5 px-2 text-base-content/60"
                />
                <button
                  type="button"
                  phx-click="remove_volume"
                  phx-value-index={idx}
                  class="p-1.5 text-base-content/40 hover:text-error cursor-pointer"
                  aria-label={"Remove volume #{vol["container_path"]}"}
                >
                  <.icon name="hero-trash" class="size-3.5" />
                </button>
              </div>

              <button
                type="button"
                phx-click="add_volume"
                class="text-xs text-primary hover:underline cursor-pointer"
              >
                + Add volume
              </button>

              <div class="rounded-lg bg-warning/10 border border-warning/20 px-3 py-2">
                <p class="text-[11px] text-base-content/70 leading-snug">
                  <strong>Managed</strong>
                  — Docker owns the data in a named volume. Its name is derived from the mount
                  path, so <strong>changing that path does not move the data</strong>: it mounts
                  a new, empty volume and leaves the old one behind.
                </p>
                <p class="text-[11px] text-base-content/70 leading-snug">
                  <strong>Folder</strong>
                  — mounts a host directory you already have; this is how the pre-homelab stack
                  works. The path is on the <em>host</em>, not inside this container.
                </p>
                <p class="text-[11px] text-base-content/70 leading-snug">
                  Saving recreates the container. Removing a row detaches the volume; it does
                  not delete it.
                </p>
              </div>

              <.button
                type="submit"
                label="Save"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium"
              />
            </.form>

            <table :if={!@volumes_edit_mode} class="w-full text-sm">
              <thead>
                <tr class="border-b border-base-content/10">
                  <th class="text-left py-2 font-medium text-base-content/70">Name</th>
                  <th class="text-left py-2 font-medium text-base-content/70">Mount path</th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={vol <- Access.effective_volumes(@deployment)}
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
              :if={!@volumes_edit_mode and Access.effective_volumes(@deployment) == []}
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
            <.button
              type="button"
              phx-click="trigger_backup"
              label="Back up"
              class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors"
            />
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

        <%!-- Releases tab --%>
        <div :if={@active_tab == "releases"} class="space-y-4">
          <div class="flex items-center justify-between">
            <p class="text-xs text-base-content/40">
              Each release runs an ordered set of steps. A failed step stops the deploy — fix the cause and re-run.
            </p>
            <button
              :if={can_redeploy?(@driving_release)}
              type="button"
              phx-click="redeploy"
              data-confirm="Re-run the deployment steps for this stack from the start?"
              class="px-3 py-1.5 rounded-lg bg-primary text-primary-content text-xs font-medium hover:bg-primary/90 transition-colors shrink-0"
            >
              Re-run deploy
            </button>
          </div>

          <%!-- App deployments have their own release history. --%>
          <.release_card :for={release <- @releases} release={release} />

          <%!-- Companion deployments (db/redis) have no release of their own —
                surface the app's release that provisions them, so their state and
                errors are visible instead of a bare "no releases yet". --%>
          <div :if={@releases == [] && @driving_release}>
            <p class="text-xs text-base-content/50 mb-2">
              This deployment is provisioned as part of another release:
            </p>
            <.release_card release={@driving_release} />
          </div>

          <p
            :if={@releases == [] && is_nil(@driving_release)}
            class="text-sm text-base-content/50 py-4"
          >
            No releases yet. Multi-step deploys and adoptions appear here as they run.
          </p>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp assign_readiness(socket) do
    assign(socket, :readiness, Readiness.checks(socket.assigns.deployment))
  end

  defp merged_env(deployment) do
    template = deployment.app_template
    base = template.default_env || %{}
    overrides = deployment.env_overrides || %{}
    Map.merge(base, overrides)
  end

  # The env editor edits KEYS as well as values. It used to render one input per
  # existing key, so a variable the template never declared could not be added at all
  # -- and an app whose requirements changed after packaging (aut.hair gaining REVERB_*)
  # had no way in short of rebuilding the catalog entry.
  defp env_rows(env) do
    env
    |> Enum.sort_by(fn {key, _value} -> key end)
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => to_string(value)} end)
  end

  # The editor posts indexed rows (%{"0" => %{"key" =>, "value" =>}}) because the key
  # is editable. A flat %{"KEY" => "value"} map is still accepted so a caller that
  # only wants to set values doesn't have to know about row indices.
  defp rows_from_params(nil), do: []

  defp rows_from_params(params) when is_map(params) do
    if Enum.all?(params, fn {_k, value} -> is_map(value) end) do
      params
      |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
      |> Enum.map(fn {_idx, row} ->
        %{"key" => row["key"] || "", "value" => row["value"] || ""}
      end)
    else
      params
      |> Enum.sort_by(fn {key, _value} -> key end)
      |> Enum.map(fn {key, value} -> %{"key" => key, "value" => to_string(value)} end)
    end
  end

  defp secret_key?(key) do
    upper = String.upcase(key)
    String.contains?(upper, "PASSWORD") or String.contains?(upper, "SECRET")
  end

  # An inherit/custom pair plus a textarea. The pair exists because a blank textarea
  # alone cannot distinguish "use the catalog's" from "explicitly nothing", and for
  # entrypoint those mean genuinely different things to Docker.
  attr :name, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, required: true
  attr :mode, :string, required: true
  attr :value, :string, required: true

  defp runtime_list_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label class="text-xs font-medium text-base-content/50">{@label}</label>
      <select
        name={"runtime[#{@name}_mode]"}
        class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
      >
        <option value="inherit" selected={@mode == "inherit"}>Inherit from catalog</option>
        <option value="custom" selected={@mode == "custom"}>Custom</option>
      </select>
      <textarea
        :if={@mode == "custom"}
        name={"runtime[#{@name}]"}
        rows="3"
        class="rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
      >{@value}</textarea>
      <p class="text-xs text-base-content/40">{@hint}</p>
    </div>
    """
  end

  defp swarm?, do: Homelab.Config.orchestrator() == Homelab.Orchestrators.DockerSwarm

  defp format_list(nil), do: "—"
  defp format_list([]), do: "(none)"
  defp format_list(values), do: Enum.join(values, " ")

  # One argument per line, not a shell string. Splitting `--flag "a b"` on whitespace
  # gets it wrong, and the alternative is implementing shell quoting in a form field.
  defp assign_list_field(socket, key, nil) do
    socket
    |> assign(:"runtime_#{key}_mode", "inherit")
    |> assign(:"runtime_#{key}", "")
  end

  defp assign_list_field(socket, key, values) when is_list(values) do
    socket
    |> assign(:"runtime_#{key}_mode", "custom")
    |> assign(:"runtime_#{key}", Enum.join(values, "\n"))
  end

  # "inherit" is nil; "custom" is a list, and an EMPTY custom list is a real value —
  # clearing an image's entrypoint is a Docker instruction, not an absent setting.
  defp parse_list_field("custom", text) do
    (text || "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp parse_list_field(_inherit, _text), do: nil

  # Blank means "the platform default", which is what nil resolves to.
  defp parse_replicas(value) do
    case Integer.parse(to_string(value)) do
      {n, _rest} when n > 0 -> n
      _ -> nil
    end
  end

  # A version change is `apply_config/2` with a different image — the pull-and-converge
  # sequence was always there, it had just never been handed anything different to run.
  defp apply_version(socket, override) do
    deployment = socket.assigns.deployment

    case apply_config(deployment, %{image_override: override}) do
      {:ok, updated} ->
        message =
          if override,
            do: "Now running #{override} — recreating the container.",
            else: "Reset to the catalog default — recreating the container."

        {:noreply,
         socket
         |> assign(:deployment, updated)
         |> assign_readiness()
         |> assign(version_edit_mode: false, available_tags: :idle)
         |> put_flash(:info, message)}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  # `start_async` rather than a supervised Task: it is scoped to this LiveView, so a
  # registry that hangs cannot outlive the page that asked, and the result arrives via
  # `handle_async/3` whether the fetch returned or crashed. Same reasoning as the TLS
  # probe's dedicated supervisor — per-open-page UI work must not borrow the bounded
  # worker pool and starve real background jobs — reached a simpler way.
  defp load_available_tags(socket) do
    image = socket.assigns.version_image

    if connected?(socket) and Tags.supported?(image) do
      socket
      |> assign(:available_tags, :loading)
      |> start_async(:available_tags, fn -> Tags.available_for(image) end)
    else
      # Unsupported is not a failure: the free-text field is the real control, and the
      # picker is a convenience on top of it.
      assign(socket, :available_tags, :idle)
    end
  end

  # Persists config attrs then recreates the container so the changes take effect.
  defp apply_config(deployment, attrs) do
    with {:ok, updated} <- Deployments.update_deployment(deployment, attrs),
         {:ok, _} <- Deployments.recreate_deployment(updated) do
      {:ok, Deployments.get_deployment!(updated.id)}
    else
      {:error, %Ecto.Changeset{}} -> {:error, "Could not save the configuration."}
      {:error, reason} -> {:error, "Saved, but recreate failed: #{inspect(reason)}"}
    end
  end

  # Normalizes stored ports into the container->host rows the Host editor renders.
  # Carries the ROLE through the form. The settings form used to post only
  # internal/external, so `ConfigForm` re-inferred the role from the port number on
  # every save — and an app on a non-obvious port lost its explicit "web"
  # designation, which is the one the reverse proxy routes to.
  defp editable_ports(ports) do
    Enum.map(ports, fn p ->
      %{
        "internal" => to_string(p["internal"] || p["container_port"] || ""),
        "external" => to_string(p["external"] || p["host_port"] || ""),
        "role" => p["role"] || "other",
        "description" => p["description"] || "",
        "optional" => p["optional"] == true
      }
    end)
  end

  # Reads the live form's indexed port params, keeping every row (incl. blanks)
  # so add/remove don't drop a row mid-edit. Save uses ConfigForm for the final
  # normalized override.
  defp ports_from_params(ports) when is_map(ports) do
    ports
    |> Enum.sort_by(fn {i, _} -> String.to_integer(i) end)
    |> Enum.map(fn {_, p} ->
      %{
        "internal" => p["internal"] || "",
        "external" => p["external"] || "",
        "role" => p["role"] || "other",
        "description" => p["description"] || "",
        "optional" => p["optional"] == "true"
      }
    end)
  end

  defp ports_from_params(_), do: []

  # Off-process: the probe is a TLS handshake against a possibly-unreachable host, and
  # the page must not freeze for its timeout. async_nolink so a failed probe cannot take
  # the LiveView down with it.
  defp probe_tls(%{assigns: %{deployment: %{domain: domain}}} = socket)
       when is_binary(domain) and domain != "" do
    if connected?(socket) do
      probe = tls_probe_impl()

      Task.Supervisor.async_nolink(Homelab.TlsProbeSupervisor, fn ->
        {:tls_probed, probe.inspect_domain(domain)}
      end)

      assign(socket, :tls, :loading)
    else
      assign(socket, :tls, :idle)
    end
  end

  # No domain means nothing is served over TLS — there is no certificate to report.
  defp probe_tls(socket), do: assign(socket, :tls, :no_domain)

  # Swappable so tests don't reach out to the real internet on every page mount.
  defp tls_probe_impl,
    do: Application.get_env(:homelab, :tls_probe, Homelab.Networking.TlsProbe)

  # Which radio is checked: the port Traefik will ACTUALLY forward to. A stored
  # routed_port is the operator's decision and wins outright; only a deployment that
  # has never made one falls back to SpecBuilder's guess (mirrored here so the form
  # never shows a different port than the one the spec will use).
  defp checked_routed_port(%{routed_port: port}, _ports) when is_integer(port),
    do: to_string(port)

  defp checked_routed_port(_deployment, ports) do
    port =
      Enum.find(ports, &(&1["role"] == "web")) ||
        Enum.find(ports, &(&1["optional"] != true)) ||
        List.first(ports)

    to_string(port && port["internal"])
  end

  # Volume rows, as the Volumes tab holds them. `target` is the shape a spec-built
  # volume carries; `container_path` the shape the template and the override carry.
  # Both go through VolumeSpec. This used to carry its own inference ("a volume with a
  # source is a bind unless it says otherwise") which contradicted SpecBuilder's ("a
  # volume with a source is a VOLUME unless it says otherwise") -- so an adopted named
  # volume displayed as a folder mount, and the two disagreed about what was mounted.
  defp volume_rows(volumes), do: VolumeSpec.parse_rows(List.wrap(volumes))

  defp volume_rows_from_params(params), do: VolumeSpec.parse_rows(params)

  # Extra path routes, as the form holds them (strings) and as the DB holds them (a
  # path plus an integer port).
  defp editable_routes(routes) do
    routes
    |> List.wrap()
    |> Enum.map(fn route ->
      %{
        "path_prefix" => route["path_prefix"] || "",
        "port" => to_string(route["port"] || "")
      }
    end)
  end

  defp routes_from_params(nil), do: []

  defp routes_from_params(params) when is_map(params) do
    params
    |> Enum.sort_by(fn {idx, _row} -> String.to_integer(idx) end)
    |> Enum.map(fn {_idx, row} ->
      %{"path_prefix" => row["path_prefix"] || "", "port" => row["port"] || ""}
    end)
  end

  # A half-filled row is dropped, not saved as a broken route. The changeset would
  # reject it anyway; discarding it here means an operator who added a row and changed
  # their mind isn't blocked by a validation error on a field they left blank.
  defp parse_routes(params) do
    params
    |> routes_from_params()
    |> Enum.reject(fn route ->
      String.trim(route["path_prefix"]) == "" or String.trim(to_string(route["port"])) == ""
    end)
    |> Enum.map(fn route ->
      %{
        "path_prefix" => String.trim(route["path_prefix"]),
        "port" => parse_routed_port(to_string(route["port"]))
      }
    end)
  end

  # The radio carries the port NUMBER, not its row index -- an index would silently
  # re-point the proxy at a different port if the rows were ever reordered.
  defp parse_routed_port(value) when is_binary(value) and value != "" do
    case Integer.parse(value) do
      {port, ""} -> port
      _ -> nil
    end
  end

  defp parse_routed_port(_value), do: nil

  # Proxy-only options. Sticky sessions pin a client to one replica: Traefik
  # round-robins otherwise, and a websocket (or LiveView) reconnect landing on a
  # different container drops the session.
  defp proxy_options(settings, "proxy"), do: %{"sticky" => settings["sticky"] == "true"}
  defp proxy_options(_settings, _access), do: %{}

  defp blank_to_nil(v) when v in [nil, ""], do: nil
  defp blank_to_nil(v), do: v

  # Build the resource-limits override from the form. Only the fields the user
  # filled are set; an all-blank section means "inherit the template" (nil).
  defp limits_override(settings) do
    limits =
      %{
        "memory_mb" => parse_pos_int(settings["memory_mb"]),
        "cpu_shares" => parse_pos_int(settings["cpu_shares"]),
        "gpu" => gpu_override(settings)
      }
      |> Enum.reject(fn {_k, v} -> is_nil(v) end)
      |> Map.new()

    if limits == %{}, do: nil, else: limits
  end

  # The advertised kinds come from the CLUSTER, not from our conventions: Swarm matches
  # the kind byte-for-byte against daemon.json, so offering the operator a guess would be
  # offering them a task that hangs pending. Read once, on entering edit mode.
  defp assign_gpu_settings(socket, limits) do
    gpu = Homelab.Deployments.GpuSpec.parse(limits) || %{}

    kinds =
      case Homelab.Infrastructure.GpuFacts.advertised_kinds() do
        {:ok, kinds} -> kinds
        {:error, _reason} -> []
      end

    socket
    |> assign(:settings_gpu_vendor, Map.get(gpu, :vendor, ""))
    |> assign(:settings_gpu_count, to_string(Map.get(gpu, :count, "")))
    |> assign(:settings_gpu_devices, Map.get(gpu, :devices, ""))
    |> assign(:settings_gpu_kind, Map.get(gpu, :kind, ""))
    |> assign(:gpu_advertised_kinds, kinds)
  end

  # A GPU is a resource reservation, so it rides in resource_limits — which is already a
  # free-form map on both schemas, hence no migration. "none" means no GPU, not "inherit":
  # the whole limits map is a wholesale override, so a half-map would silently drop the
  # memory limit too.
  defp gpu_override(settings) do
    case settings["gpu_vendor"] do
      vendor when vendor in ["nvidia", "amd"] ->
        %{
          "vendor" => vendor,
          "count" => parse_pos_int(settings["gpu_count"]) || 1,
          "devices" => blank_default(settings["gpu_devices"], "all"),
          # Must match the node's daemon.json byte-for-byte under Swarm. Prefilled from
          # what the cluster actually advertises, not from a convention we hope holds.
          "kind" =>
            blank_default(settings["gpu_kind"], Homelab.Deployments.GpuSpec.default_kind(vendor))
        }

      _ ->
        nil
    end
  end

  defp blank_default(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp blank_default(_value, default), do: default

  # Build the healthcheck override. A blank path inherits the template; a path
  # merges onto the effective check so existing intervals/timeouts are kept.
  defp health_override(deployment, settings) do
    case blank_to_nil(settings["health_path"]) do
      nil -> nil
      path -> Map.put(Access.effective_health_check(deployment), "path", path)
    end
  end

  defp parse_pos_int(value) do
    case value |> to_string() |> Integer.parse() do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  # Human-readable summary of a deployment's access for the read-only view.
  defp settings_access_label(deployment) do
    exposure = Access.effective_exposure(deployment)

    case Access.access_of(exposure) do
      "proxy" -> "Reverse proxy (#{auth_label(Access.auth_of(exposure))})"
      "host" -> "Host ports"
      "host_network" -> "Host network"
      "internal" -> "Internal only"
    end
  end

  defp auth_label("sso_protected"), do: "SSO"
  defp auth_label("private"), do: "private"
  defp auth_label(_), do: "no auth"

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
    limit = stats.memory_limit

    # Docker reports a 0 memory_limit for containers with no limit set; `|| 1`
    # doesn't catch 0 (truthy in Elixir), so guard explicitly to avoid a
    # divide-by-zero ArithmeticError.
    if is_number(limit) and limit > 0 do
      min_val(round(usage / limit * 100), 100)
    else
      0
    end
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
  defp pill_classes(:planning), do: "bg-info/10 text-info"
  defp pill_classes(:provisioning), do: "bg-info/10 text-info"
  defp pill_classes(:rolling_back), do: "bg-warning/10 text-warning"
  defp pill_classes(:rolled_back), do: "bg-base-200 text-base-content/50"
  defp pill_classes(:rollback_failed), do: "bg-error/10 text-error"
  defp pill_classes(:compensating), do: "bg-warning/10 text-warning"
  defp pill_classes(:compensated), do: "bg-base-200 text-base-content/50"
  defp pill_classes(:skipped), do: "bg-base-200 text-base-content/50"
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
  defp format_status(:planning), do: "Planning"
  defp format_status(:provisioning), do: "Provisioning"
  defp format_status(:rolling_back), do: "Rolling back"
  defp format_status(:rolled_back), do: "Rolled back"
  defp format_status(:rollback_failed), do: "Rollback failed"
  defp format_status(:compensating), do: "Compensating"
  defp format_status(:compensated), do: "Compensated"
  defp format_status(:skipped), do: "Skipped"
  defp format_status(status), do: to_string(status)

  # Icon for a release step's status.
  defp step_icon(:completed), do: {"hero-check-circle", "text-success"}
  defp step_icon(:running), do: {"hero-arrow-path", "text-info animate-spin"}
  defp step_icon(:failed), do: {"hero-exclamation-circle", "text-error"}
  defp step_icon(:compensating), do: {"hero-arrow-uturn-left", "text-warning"}
  defp step_icon(:compensated), do: {"hero-arrow-uturn-left", "text-base-content/40"}
  defp step_icon(:skipped), do: {"hero-minus-circle", "text-base-content/40"}
  defp step_icon(_pending), do: {"hero-clock", "text-base-content/30"}

  # Re-run is offered only when no release is in flight — a live saga must not be
  # re-driven, and the one-active-per-deployment constraint would reject the plan.
  defp can_redeploy?(nil), do: true

  defp can_redeploy?(%Homelab.Deployments.Release{} = r),
    do: Homelab.Deployments.Release.terminal?(r)

  defp can_redeploy?(_), do: false

  # The first step that failed on a release, if any — the reason the stack stalled.
  defp failed_step(%Homelab.Deployments.Release{steps: steps}) when is_list(steps),
    do: Enum.find(Enum.sort_by(steps, & &1.position), &(&1.status == :failed))

  defp failed_step(_), do: nil

  # What the domain is ACTUALLY serving, read from the live TLS handshake rather than
  # from Traefik's opinion — Traefik reports a router as "active" even while it serves
  # its self-signed default because ACME failed, which is the exact failure mode a
  # custom (non-wildcard) domain hits.
  attr :tls, :any, required: true
  attr :domain, :string, default: nil

  defp tls_card(assigns) do
    ~H"""
    <div :if={@tls != :no_domain} class="rounded-lg bg-base-100 border border-base-content/5 p-4">
      <div class="flex items-center justify-between gap-3">
        <div class="flex items-center gap-2">
          <.icon name="hero-lock-closed" class="size-4 text-base-content/40" />
          <span class="text-sm font-semibold text-base-content">TLS certificate</span>
          <span class="text-[11px] text-base-content/40">{@domain}</span>
        </div>
        <button
          type="button"
          phx-click="recheck_tls"
          class="text-[11px] text-primary hover:text-primary/80 cursor-pointer"
        >
          Re-check
        </button>
      </div>

      <p :if={@tls in [:loading, :idle]} class="mt-2 text-xs text-base-content/40">
        Checking the certificate being served…
      </p>

      <div :if={match?({:error, _}, @tls)} class="mt-2 flex items-start gap-2">
        <.icon name="hero-exclamation-triangle" class="size-4 text-error shrink-0 mt-0.5" />
        <div>
          <p class="text-xs font-medium text-error">Could not complete a TLS handshake</p>
          <p class="text-[11px] text-base-content/40">
            Nothing is answering on :443 for this name — the DNS record, the route, or the
            app itself is not up. {inspect(elem(@tls, 1))}
          </p>
        </div>
      </div>

      <div :if={match?({:ok, _}, @tls)} class="mt-3 space-y-2">
        <% cert = elem(@tls, 1) %>
        <div class="flex items-center gap-2">
          <span class={[
            "px-2 py-0.5 rounded text-[10px] font-semibold uppercase tracking-wide",
            tls_badge_class(cert.status)
          ]}>
            {tls_status_label(cert.status)}
          </span>
          <span class="text-xs text-base-content/60">
            {tls_status_detail(cert)}
          </span>
        </div>

        <dl class="grid grid-cols-2 gap-x-6 gap-y-1 text-[11px]">
          <div class="flex justify-between">
            <dt class="text-base-content/40">Issuer</dt>
            <dd class="text-base-content/70 font-medium truncate ml-2">{cert.issuer}</dd>
          </div>
          <div class="flex justify-between">
            <dt class="text-base-content/40">Expires</dt>
            <dd class={[
              "font-medium ml-2",
              if(cert.days_remaining <= 21, do: "text-warning", else: "text-base-content/70")
            ]}>
              {Calendar.strftime(cert.not_after, "%Y-%m-%d")} ({cert.days_remaining}d)
            </dd>
          </div>
          <div class="flex justify-between col-span-2">
            <dt class="text-base-content/40">Covers</dt>
            <dd class="text-base-content/70 font-medium ml-2 truncate">
              {Enum.join(cert.sans, ", ")}
            </dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  # A self-signed cert is the headline: the browser rejects it outright, and it is what
  # Traefik serves when ACME could not issue for this name.
  defp tls_status_label(:valid), do: "Valid"
  defp tls_status_label(:expiring), do: "Expiring"
  defp tls_status_label(:expired), do: "Expired"
  defp tls_status_label(:self_signed), do: "Self-signed"
  defp tls_status_label(:name_mismatch), do: "Wrong name"

  defp tls_badge_class(:valid), do: "bg-success/10 text-success"
  defp tls_badge_class(:expiring), do: "bg-warning/10 text-warning"

  defp tls_badge_class(status) when status in [:expired, :self_signed, :name_mismatch],
    do: "bg-error/10 text-error"

  defp tls_status_detail(%{status: :self_signed}),
    do: "Traefik is serving its default certificate — ACME never issued a real one."

  defp tls_status_detail(%{status: :name_mismatch, subject: subject}),
    do: "The served certificate is for #{subject}, not this domain."

  defp tls_status_detail(%{status: :expired}), do: "Browsers are rejecting this certificate."

  defp tls_status_detail(%{status: :expiring, days_remaining: days}),
    do: "Renews automatically; #{days} days left."

  defp tls_status_detail(%{issuer: issuer}), do: "Issued by #{issuer}."

  # One release: header (status + time + lease), any release-level error, then the
  # ordered steps with per-step status and error.
  attr :release, :map, required: true

  defp release_card(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
        <div class="flex items-center gap-3">
          <.status_pill status={@release.status} />
          <span class="text-xs text-base-content/40">
            {Calendar.strftime(@release.inserted_at, "%b %d, %Y %H:%M")}
          </span>
        </div>
        <span :if={@release.lease_owner} class="text-[11px] text-base-content/40 font-mono">
          lease: {@release.lease_owner}
        </span>
      </div>

      <div
        :if={@release.error_message}
        class="px-4 py-2 bg-error/5 text-error text-xs border-b border-error/10"
      >
        {@release.error_message}
      </div>

      <ul class="divide-y divide-base-content/5">
        <li
          :for={step <- Enum.sort_by(@release.steps, & &1.position)}
          class="flex items-start gap-3 px-4 py-2.5"
        >
          <% {icon, icon_class} = step_icon(step.status) %>
          <.icon name={icon} class={["size-4 mt-0.5 shrink-0", icon_class]} />
          <div class="min-w-0">
            <p class="text-sm text-base-content">
              {step.type |> to_string() |> String.replace("_", " ")}
              <span class="text-xs text-base-content/40">· {format_status(step.status)}</span>
            </p>
            <p :if={step.error_message} class="text-xs text-error mt-0.5 break-words">
              {step.error_message}
            </p>
          </div>
        </li>
      </ul>
    </div>
    """
  end
end
