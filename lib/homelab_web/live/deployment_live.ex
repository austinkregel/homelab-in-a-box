defmodule HomelabWeb.DeploymentLive do
  use HomelabWeb, :live_view

  alias Homelab.Deployments
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Netns
  alias Homelab.Deployments.Readiness
  alias Homelab.Deployments.ReleaseStep
  alias Homelab.Deployments.SettingsForm
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Deployments.VolumeSpec
  alias Homelab.Catalog.Tags
  alias Homelab.Backups
  alias Homelab.Services.BackupScheduler
  alias Homelab.Storage
  alias HomelabWeb.DeploymentSettings
  alias HomelabWeb.SecretReveal

  @tabs ~w(overview settings topology traffic logs environment volumes backups releases)

  @log_poll_interval 3_000

  # Both re-run refusals mean the same thing to the operator: something else is driving
  # a deployment this would touch.
  @release_in_flight_flash "A release is already in flight for this stack. " <>
                             "Wait for it to finish before re-running."

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(:page_title, "Deployment")
      |> assign(:deployment, nil)
      |> assign(:readiness, [])
      |> assign(:active_tab, "overview")
      |> assign(:tabs, @tabs)
      |> assign(:logs, "")
      |> assign(:logs_loading, false)
      |> assign(:follow_logs, false)
      |> assign(:log_timer, nil)
      |> assign(:env_edit_mode, false)
      |> assign(:env_form, nil)
      |> assign(:env_rows, [])
      |> assign(:revealed_env, MapSet.new())
      |> assign(:settings_edit_mode, false)
      # The pristine read and the edited one. Everything the tab renders -- the dirty
      # count, the review sheet, the derived summary -- is a comparison of the pair.
      |> assign(:settings_form, %SettingsForm{})
      |> assign(:settings_base, %SettingsForm{})
      |> assign(:settings_review, nil)
      |> assign(:volumes_edit_mode, false)
      |> assign(:volumes_rows, [])
      |> assign(:known_volumes, [])
      |> assign(:gpu_advertised_kinds, [])
      |> assign(:netns_candidates, [])
      |> assign(:netns_donor, nil)
      |> assign(:netns_children, [])
      |> assign(:netns_donor_env, %{})
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
  def handle_params(%{"id" => id} = params, _uri, socket) do
    id = String.to_integer(id)

    socket =
      if socket.assigns.deployment && socket.assigns.deployment.id == id do
        socket
      else
        load_deployment(socket, id)
      end

    {:noreply, apply_tab(socket, params["tab"])}
  end

  # Everything a tab switch must NOT redo: the queries, the TLS probe, and the
  # PubSub subscriptions, which would otherwise stack up one duplicate per click.
  defp load_deployment(socket, id) do
    deployment = Deployments.get_deployment!(id)
    tenants = Homelab.Tenants.list_active_tenants()

    siblings = Deployments.list_deployments_for_tenant(deployment.tenant_id)

    socket =
      socket
      |> assign(:deployment, deployment)
      |> assign(:page_title, deployment.app_template.name)
      |> assign(:tenants, tenants)
      |> assign(:siblings, siblings)
      |> assign_releases()
      |> assign_derived()
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

    socket
  end

  # The tab is a URL parameter, so a deep link, a refresh and the back button all
  # land where they say they do. An unknown or missing tab falls back to overview
  # rather than rendering a page with no visible panel.
  defp apply_tab(socket, tab) when tab in @tabs do
    socket =
      if tab == "logs" do
        send(self(), :load_logs)
        assign(socket, :logs_loading, true)
      else
        if socket.assigns.log_timer, do: Process.cancel_timer(socket.assigns.log_timer)

        socket
        |> assign(:follow_logs, false)
        |> assign(:log_timer, nil)
      end

    assign(socket, :active_tab, tab)
  end

  defp apply_tab(socket, _tab), do: apply_tab(socket, "overview")

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
      {:noreply, socket |> assign(:deployment, deployment) |> assign_derived()}
    else
      {:noreply, socket}
    end
  end

  def handle_info(
        {:release_updated, _release_deployment_id},
        %{assigns: %{deployment: nil}} = socket
      ),
      do: {:noreply, socket}

  def handle_info({:release_updated, _release_deployment_id}, socket) do
    # We only subscribe to topics for this deployment and its driving release, so
    # any release update we receive is relevant — refresh the deployment row, the
    # release history, and the driving release together.
    deployment = Deployments.get_deployment!(socket.assigns.deployment.id)

    {:noreply,
     socket
     |> assign(:deployment, deployment)
     |> assign_releases()
     |> assign_derived()}
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
    {:noreply,
     push_patch(socket, to: ~p"/deployments/#{socket.assigns.deployment.id}?tab=#{tab}")}
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
     |> assign(:env_rows, env_rows(merged_env(deployment)))
     |> assign(:revealed_env, MapSet.new())}
  end

  def handle_event("cancel_env_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:env_edit_mode, false)
     |> assign(:env_form, nil)
     |> assign(:env_rows, [])
     |> assign(:revealed_env, MapSet.new())}
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
    idx = String.to_integer(idx)
    rows = List.delete_at(socket.assigns.env_rows, idx)

    {:noreply,
     socket
     |> assign(:env_rows, rows)
     |> assign(:revealed_env, SecretReveal.drop_index(socket.assigns.revealed_env, idx))}
  end

  def handle_event("toggle_env_visibility", %{"secret" => idx}, socket) do
    {:noreply,
     assign(socket, :revealed_env, SecretReveal.toggle(socket.assigns.revealed_env, idx))}
  end

  # A real submission carries the form's rows, its marker, or both. Anything arriving
  # with neither sent no inputs at all — which is a control that is not wired to the
  # form, not an operator asking for zero variables. Answering it by writing `%{}` is a
  # silent, total, unrecoverable wipe of every credential on the deployment, reported as
  # "Environment updated". Refuse instead; the marker keeps a genuine clear-them-all
  # working (see `deleting every row still clears the environment`).
  def handle_event("save_env", %{"env" => _} = params, socket), do: save_env(params, socket)

  def handle_event("save_env", %{"env_submitted" => "1"} = params, socket),
    do: save_env(params, socket)

  def handle_event("save_env", _params, socket) do
    {:noreply,
     put_flash(socket, :error, "No environment variables were submitted — nothing was changed.")}
  end

  # --- Version ---
  #
  # A separate card and a separate form from the rest of Settings, deliberately. Every
  # other field here is a config tweak; changing the image is the one action that can
  # replace the software the operator's data is sitting under.

  # --- Settings: one editor over the whole configuration ---

  def handle_event("start_settings_edit", _params, socket) do
    deployment = socket.assigns.deployment
    form = SettingsForm.from_deployment(deployment)

    # The registry list and the cluster's GPU kinds are read when the editor OPENS, not
    # on mount: both are only ever needed by this form, and every other tab on the page
    # would otherwise pay for them.
    {:noreply,
     socket
     |> assign(:settings_edit_mode, true)
     |> assign(:settings_form, form)
     |> assign(:settings_base, form)
     |> assign(:settings_review, nil)
     |> assign(:netns_candidates, netns_candidates(deployment))
     |> assign(:gpu_advertised_kinds, advertised_gpu_kinds())
     |> load_available_tags()}
  end

  def handle_event("cancel_settings_edit", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_edit_mode, false)
     |> assign(:settings_review, nil)
     |> assign(:settings_form, socket.assigns.settings_base)}
  end

  # Every field round-trips through the struct as the operator types. A control whose
  # value is recomputed from the deployment per render reverts under the cursor as soon
  # as anything else is touched, and the save then writes the value they replaced.
  def handle_event("settings_changed", %{"settings" => settings}, socket) do
    {:noreply,
     assign(
       socket,
       :settings_form,
       SettingsForm.from_params(socket.assigns.settings_form, settings)
     )}
  end

  def handle_event("settings_changed", _params, socket), do: {:noreply, socket}

  def handle_event("recheck_tls", _params, socket) do
    {:noreply, probe_tls(socket)}
  end

  def handle_event("settings_add_port", _params, socket) do
    blank = %{
      "internal" => "",
      "external" => "",
      "role" => "other",
      "protocol" => "tcp",
      "description" => "",
      "optional" => false,
      "host_ip" => nil,
      "exposure" => nil
    }

    {:noreply,
     update_settings(socket, fn form ->
       exposure = List.first(SettingsForm.allowed_exposures(form))
       %{form | ports: form.ports ++ [Map.put(blank, "exposure", exposure)]}
     end)}
  end

  def handle_event("settings_remove_port", %{"index" => index}, socket) do
    {:noreply,
     update_settings(socket, fn form ->
       %{form | ports: List.delete_at(form.ports, String.to_integer(index))}
     end)}
  end

  def handle_event("start_volumes_edit", _params, socket) do
    rows = volume_rows(Access.effective_volumes(socket.assigns.deployment))

    # The daemon's volume list is read when the editor OPENS, not on mount: it is only
    # ever needed to suggest names in this one form, and every other tab on the page
    # would pay for it.
    {:noreply,
     socket
     |> assign(:volumes_edit_mode, true)
     |> assign(:volumes_rows, rows)
     |> assign(:known_volumes, Storage.volume_names())}
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
    # Which rows borrow their data is decided against what this deployment mounted
    # BEFORE this save, so re-pointing a row at an existing volume marks it while editing
    # any other field leaves the answer alone.
    volumes =
      VolumeSpec.mark_borrowed(
        VolumeSpec.parse(params["volumes"]),
        Access.effective_volumes(deployment),
        socket.assigns.known_volumes
      )

    case apply_config(deployment, %{volumes_override: volumes}) do
      {:ok, updated, _release} ->
        {:noreply,
         socket
         |> assign_applied(updated)
         |> assign(:volumes_edit_mode, false)
         |> assign(:volumes_rows, [])
         |> put_flash(:info, "Volumes updated — #{release_started_flash(false)}")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

  def handle_event("settings_add_route", _params, socket) do
    form = socket.assigns.settings_form

    # A new row inherits the primary's host and the first proxied port, because the
    # overwhelmingly common second route is another path on the same hostname. Typing
    # the host again for every row is how the old three-editor split felt.
    blank = %{
      "host" => first_route_host(form),
      "path_prefix" => "",
      "port" => default_route_port(form),
      "primary" => form.routes == []
    }

    {:noreply, update_settings(socket, fn form -> %{form | routes: form.routes ++ [blank]} end)}
  end

  def handle_event("settings_remove_route", %{"index" => index}, socket) do
    {:noreply,
     update_settings(socket, fn form ->
       %{form | routes: List.delete_at(form.routes, String.to_integer(index))}
     end)}
  end

  def handle_event("settings_add_device", _params, socket) do
    blank = %{"host_path" => "", "container_path" => "", "permissions" => "rwm"}
    {:noreply, update_settings(socket, fn form -> %{form | devices: form.devices ++ [blank]} end)}
  end

  def handle_event("settings_remove_device", %{"index" => index}, socket) do
    {:noreply,
     update_settings(socket, fn form ->
       %{form | devices: List.delete_at(form.devices, String.to_integer(index))}
     end)}
  end

  def handle_event("settings_add_sysctl", _params, socket) do
    blank = %{"key" => "", "value" => ""}
    {:noreply, update_settings(socket, fn form -> %{form | sysctls: form.sysctls ++ [blank]} end)}
  end

  def handle_event("settings_remove_sysctl", %{"index" => index}, socket) do
    {:noreply,
     update_settings(socket, fn form ->
       %{form | sysctls: List.delete_at(form.sysctls, String.to_integer(index))}
     end)}
  end

  def handle_event("settings_add_health_arg", _params, socket) do
    {:noreply, update_health(socket, &(&1 ++ [""]))}
  end

  def handle_event("settings_remove_health_arg", %{"index" => index}, socket) do
    {:noreply, update_health(socket, &List.delete_at(&1, String.to_integer(index)))}
  end

  def handle_event("settings_select_tag", %{"tag" => tag}, socket) do
    image = String.replace(socket.assigns.settings_form.image, ~r/:[^:\/]*$/, "") <> ":" <> tag
    {:noreply, update_settings(socket, fn form -> %{form | image: image} end)}
  end

  def handle_event("settings_discard", _params, socket) do
    {:noreply,
     socket
     |> assign(:settings_form, socket.assigns.settings_base)
     |> assign(:settings_review, nil)}
  end

  # The sheet is opened from the same diff the save bar counts, so the operator reviews
  # the change they were told they had rather than one recomputed on the way in.
  def handle_event("settings_review", _params, socket) do
    diff = SettingsForm.diff(socket.assigns.settings_base, socket.assigns.settings_form)
    {:noreply, assign(socket, :settings_review, diff)}
  end

  def handle_event("settings_close_review", _params, socket) do
    {:noreply, assign(socket, :settings_review, nil)}
  end

  # One save for the whole page. Version, runtime and network used to write three
  # disjoint attr maps through three submits, so an edit that touched two of them
  # recreated the container twice -- and the second recreate raced the first release.
  def handle_event("save_settings", params, socket) do
    deployment = socket.assigns.deployment

    # A submit carries the form; the review sheet's button does not, so it saves what
    # the assigns already hold rather than an empty payload.
    form =
      case params do
        %{"settings" => settings} ->
          SettingsForm.from_params(socket.assigns.settings_form, settings)

        _no_payload ->
          socket.assigns.settings_form
      end

    attrs = SettingsForm.to_attrs(form, deployment)

    # A netns member's route is served by its DONOR's labels, so changing it means
    # re-creating the donor -- which mints a new container id and leaves every OTHER
    # child naming a container that no longer exists. The whole group goes round
    # together; see Deployments.redeploy_netns_stack/1.
    stack? = netns_member?(deployment, attrs.network_parent_id)

    case apply_config(deployment, attrs, stack?) do
      {:ok, updated, _release} ->
        {:noreply,
         socket
         |> assign_applied(updated)
         |> assign(:settings_edit_mode, false)
         |> assign(:settings_review, nil)
         |> put_flash(:info, settings_saved_flash(updated, stack?))}

      {:error, message} ->
        {:noreply,
         socket
         |> assign(:settings_form, form)
         |> assign(:settings_review, nil)
         |> put_flash(:error, message)}
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
        {:noreply, put_flash(socket, :error, @release_in_flight_flash)}

      {:error, {:release_in_flight, _id}} ->
        {:noreply, put_flash(socket, :error, @release_in_flight_flash)}

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
            navigate={~p"/spaces/#{@deployment.tenant.id}"}
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
            :for={tab <- @tabs}
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
                class={[
                  action_button(),
                  "px-4 py-2 text-sm bg-success text-success-content hover:bg-success/90"
                ]}
              >
                Start
              </button>
              <button
                :if={@deployment.status == :running}
                type="button"
                phx-click="stop"
                class={[
                  action_button(),
                  "px-4 py-2 text-sm bg-warning text-warning-content hover:bg-warning/90"
                ]}
              >
                Stop
              </button>
              <button
                :if={@deployment.status == :running && @deployment.external_id}
                type="button"
                phx-click="restart"
                class={[
                  action_button(),
                  "px-4 py-2 text-sm bg-info text-info-content hover:bg-info/90"
                ]}
              >
                Restart
              </button>
              <.redeploy_button release={@driving_release} size="px-4 py-2 text-sm" />
              <button
                type="button"
                phx-click="delete"
                data-confirm="Are you sure you want to delete this deployment?"
                class={[action_button(), "px-4 py-2 text-sm bg-error/10 text-error hover:bg-error/20"]}
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
                error of its own. --%>
          <div
            :if={failed_step(@driving_release)}
            class="rounded-lg bg-error/10 border border-error/20 px-4 py-3 flex items-start gap-3"
          >
            <.icon name="hero-exclamation-triangle" class="size-5 text-error flex-shrink-0 mt-0.5" />
            <div class="min-w-0">
              <p class="text-sm font-semibold text-error">
                Deploy stopped at "{humanize_step(failed_step(@driving_release).type)}"
              </p>
              <p
                :if={failed_step(@driving_release).reason_message}
                class="text-sm text-error/80 mt-0.5 font-mono break-words"
              >
                {failed_step(@driving_release).reason_message}
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

        <%!-- Settings tab: one form over the whole configuration.
              It was three -- version, runtime, network -- each with its own Save button
              and its own container recreate, so an edit spanning two of them went round
              twice and nothing could state the combined change. --%>
        <div :if={@active_tab == "settings"} class="flex flex-col gap-4">
          <div class="flex items-center justify-between gap-3">
            <p class="text-xs text-base-content/40">
              {if @settings_edit_mode,
                do: "Changes are applied together, once, when you recreate.",
                else: "The configuration this container is running with."}
            </p>
            <button
              :if={!@settings_edit_mode}
              type="button"
              phx-click="start_settings_edit"
              class="px-3 py-1.5 rounded-lg bg-primary/10 text-primary text-sm font-medium hover:bg-primary/20 transition-colors cursor-pointer"
            >
              Edit configuration
            </button>
          </div>

          <DeploymentSettings.settings_tab
            form={@settings_form}
            base={@settings_base}
            deployment={@deployment}
            editing={@settings_edit_mode}
            netns_candidates={@netns_candidates}
            gpu_kinds={@gpu_advertised_kinds}
            available_tags={@available_tags}
            review={@settings_review}
            netns_donor={@netns_donor}
            netns_children={@netns_children}
            netns_donor_env={@netns_donor_env}
          />
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
                
    <!-- Associated with #env-form by id, not by nesting: this button lives in the section
         header and the inputs live in the card body below it. As a bare `phx-click` it
         submitted no inputs at all, and the handler read that as "zero variables" and
         deleted every one of them. -->
                <button
                  type="submit"
                  form="env-form"
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
                <!-- Proof that a submission actually happened. Deleting every row leaves the
                     form with no `env[...]` inputs, so a legitimate "clear them all" is
                     indistinguishable from a control that submitted nothing — unless the form
                     says so itself. -->
                <input type="hidden" name="env_submitted" value="1" />
                <div :for={{row, idx} <- Enum.with_index(@env_rows)} class="flex items-center gap-2">
                  <input
                    type="text"
                    name={"env[#{idx}][key]"}
                    value={row["key"]}
                    placeholder="VARIABLE"
                    class="w-2/5 rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                  <.secret_input
                    name={"env[#{idx}][value]"}
                    value={row["value"]}
                    secret={secret_key?(row["key"])}
                    revealed={MapSet.member?(@revealed_env, idx)}
                    toggle="toggle_env_visibility"
                    toggle_value={idx}
                    field_label={row["key"]}
                    placeholder="value"
                    wrapper_class="flex-1"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
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
                <%!-- The source is editable for a MANAGED volume too, not only a bind.
                      Rendering it for binds alone meant a managed row posted no source
                      at all: the name of an adopted volume — or of one attached from the
                      storage page — was dropped on the next save of this form, and
                      SpecBuilder derived a synthetic name in its place, mounting an empty
                      volume next to the real data. It is also what puts an existing
                      volume within reach here, rather than only on the storage page. --%>
                <input
                  type="text"
                  name={"volumes[#{idx}][source]"}
                  value={vol["source"]}
                  list={vol["type"] != "bind" && "known-volumes"}
                  placeholder={volume_source_placeholder(vol, @deployment)}
                  class="flex-1 rounded-lg bg-base-200 border-0 text-xs font-mono py-1.5 px-2"
                />
                <%!-- Carried rather than re-derived: a row is only re-decided when its
                      name changes, and a form that posted nothing here would hand `save`
                      a row that looks brand new. --%>
                <input
                  type="hidden"
                  name={"volumes[#{idx}][borrowed]"}
                  value={to_string(vol["borrowed"] == true)}
                />
                <span class="text-[10px] text-base-content/40">→</span>
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
                <%!-- The hidden input is what makes UNCHECKING work: an unchecked box
                      posts nothing at all, which is indistinguishable from the field not
                      being rendered. --%>
                <label
                  class="flex items-center gap-1.5 text-[11px] text-base-content/60 whitespace-nowrap"
                  title="Mount read-only — the container cannot write through it"
                >
                  <input type="hidden" name={"volumes[#{idx}][read_only]"} value="false" />
                  <input
                    type="checkbox"
                    name={"volumes[#{idx}][read_only]"}
                    value="true"
                    checked={vol["read_only"] == true}
                    class="rounded border-base-content/20"
                  /> read-only
                </label>
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

              <%!-- Every volume the daemon has, offered to each managed row's name field.
                    One list for the whole form: a datalist is referenced by id, so the
                    rows share it rather than each repeating the host's volumes. --%>
              <datalist id="known-volumes">
                <option :for={name <- @known_volumes} value={name}></option>
              </datalist>

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
                  — Docker owns the data in a named volume. Name an existing volume to mount
                  it here — any volume on this host can go into any deployment, which is how
                  one media library serves several apps. Leave the name blank and one is
                  derived from the mount path, so <strong>changing that path does not move
                  the data</strong>: it mounts a new, empty volume and leaves the old one
                  behind.
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
                <p
                  :if={Enum.any?(@volumes_rows, &(&1["borrowed"] == true))}
                  class="text-[11px] text-base-content/70 leading-snug"
                >
                  <strong>Borrowed</strong>
                  — a volume another deployment owns. Pointing the row somewhere else leaves
                  that data untouched, and so does removing the row.
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
                <%!-- The name column read `description || container_path`, and a volume
                      whose description is "" — which is every volume the wizard and the
                      storage page write — took the empty string, since "" is truthy. The
                      column was blank for every row on the page. It now says what is
                      actually mounted: the volume's name, or the host path for a folder
                      mount, deriving the name the same way SpecBuilder will when the row
                      does not carry one. --%>
                <tr
                  :for={vol <- Access.effective_volumes(@deployment)}
                  class="border-b border-base-content/5"
                >
                  <td class="py-2 font-mono text-base-content/70">
                    {volume_source_name(vol, @deployment)}
                    <span
                      :if={vol["borrowed"] == true}
                      class="ml-2 font-sans text-xs text-warning/70"
                      title="This deployment does not own this data — removing the row detaches it, it does not delete it"
                    >
                      borrowed
                    </span>
                    <span
                      :if={vol["description"] not in [nil, ""]}
                      class="ml-2 font-sans text-xs text-base-content/40"
                    >
                      {vol["description"]}
                    </span>
                  </td>
                  <td class="py-2 font-mono text-base-content">
                    {vol["container_path"] || vol["target"] || "—"}
                    <span
                      :if={vol["read_only"] == true}
                      class="ml-2 font-sans text-xs text-base-content/40"
                      title="The container cannot write through this mount"
                    >
                      read-only
                    </span>
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
            <.redeploy_button release={@driving_release} size="px-3 py-1.5 text-xs" />
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

  # Everything computed FROM the deployment rather than stored on it. Called from every
  # site that (re)assigns `:deployment`, so a save can never leave the page showing one
  # container's config next to another's derived state.
  defp assign_derived(socket) do
    deployment = socket.assigns.deployment

    socket
    |> assign(:readiness, Readiness.checks(deployment))
    |> assign_settings_form(deployment)
    |> assign_netns(deployment)
  end

  # Seeded whenever the deployment is (re)loaded, not only on entering edit mode: the
  # Settings tab renders the whole configuration in READ mode too, and a form that only
  # existed while editing is why the page used to show three rows and every screenshot
  # of it was taken mid-edit.
  #
  # An open editor keeps what the operator has typed. A save or an external update
  # re-seeds both copies, which is also what clears the dirty count.
  defp assign_settings_form(%{assigns: %{settings_edit_mode: true}} = socket, deployment) do
    assign(socket, :settings_base, SettingsForm.from_deployment(deployment))
  end

  defp assign_settings_form(socket, deployment) do
    form = SettingsForm.from_deployment(deployment)

    socket
    |> assign(:settings_form, form)
    |> assign(:settings_base, form)
  end

  # What every config save does to the page. `assign_releases/1` is the part that is
  # easy to leave out and the whole reason a save now reads as an event: `plan_release/3`
  # does not broadcast — only `transition_release/4` and `transition_step/4` do — so
  # without this the release exists but the tab keeps saying "No releases yet" until the
  # runner picks the job up. Re-reading here means the card is on screen before the
  # flash has finished animating in.
  defp assign_applied(socket, updated) do
    socket
    |> assign(:deployment, updated)
    |> assign(:settings_edit_mode, false)
    |> assign_derived()
    |> assign_releases()
  end

  defp assign_netns(socket, deployment) do
    children = Netns.children(Deployments.reload_network_children(deployment))
    donor = Netns.donor(deployment)

    socket
    |> assign(:netns_donor, donor)
    |> assign(:netns_children, children)
    # Derived, not typed — which is exactly why it is shown. A 502 through Traefik to a
    # tunneled app is almost always a port missing from FIREWALL_INPUT_PORTS, and
    # nothing in any log says so.
    |> assign(
      :netns_donor_env,
      SpecBuilder.donor_env(deployment.app_template, deployment.tenant, children)
    )
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
  # Lives down here with the other private helpers rather than beside its `handle_event`
  # clauses: a `defp` between them splits the clause group and fails
  # `--warnings-as-errors`.
  defp save_env(params, socket) do
    deployment = socket.assigns.deployment

    env_overrides =
      params["env"]
      |> rows_from_params()
      |> Enum.reject(fn row -> String.trim(row["key"] || "") == "" end)
      |> Map.new(fn row -> {String.trim(row["key"]), row["value"] || ""} end)

    case apply_config(deployment, %{env_overrides: env_overrides}) do
      {:ok, updated, _release} ->
        {:noreply,
         socket
         |> assign_applied(updated)
         |> assign(:env_edit_mode, false)
         |> assign(:env_form, nil)
         |> assign(:env_rows, [])
         |> put_flash(:info, "Environment updated — #{release_started_flash(false)}")}

      {:error, message} ->
        {:noreply, put_flash(socket, :error, message)}
    end
  end

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

  # One definition, shared with the wizard and the API serializer. This copy was the
  # narrowest of the three — only PASSWORD and SECRET — so an `API_TOKEN`, an
  # `*_API_KEY` or a `DATABASE_URL` was rendered in plaintext on the Environment tab
  # while the very same variable was masked in the wizard. See `Homelab.SecretKeys`.
  defp secret_key?(key), do: Homelab.SecretKeys.sensitive?(key)

  # The one sentence every config save ends with. A save no longer applies anything
  # itself — it plans a release and hands it to `ReleaseRunner` — so the flash points at
  # the place that shows what is actually happening instead of asserting it is done.
  defp release_started_flash(false),
    do: "release started, watch the Releases tab."

  defp release_started_flash(true),
    do: "release started for the whole network group, watch the Releases tab."

  # `start_async` rather than a supervised Task: it is scoped to this LiveView, so a
  # registry that hangs cannot outlive the page that asked, and the result arrives via
  # `handle_async/3` whether the fetch returned or crashed. Same reasoning as the TLS
  # probe's dedicated supervisor — per-open-page UI work must not borrow the bounded
  # worker pool and starve real background jobs — reached a simpler way.
  defp load_available_tags(socket) do
    image = socket.assigns.settings_form.image

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

  # Persists config attrs then plans a release that applies them to the workload.
  #
  # Returns the reloaded deployment AND the release driving it, because the caller has
  # to say which of the two happened: the save is synchronous and done, the apply is a
  # saga that has only just been enqueued. Every flash on this path used to promise
  # "recreating the container" in the past tense for work that had not started.
  # Every settings edit is the same shape: transform the struct, then settle it against
  # the rules it cannot break, so the page never renders a configuration the save would
  # refuse.
  defp update_settings(socket, fun) do
    assign(socket, :settings_form, SettingsForm.normalize(fun.(socket.assigns.settings_form)))
  end

  defp update_health(socket, fun) do
    update_settings(socket, fn form ->
      %{form | health: Map.update(form.health, "args", [""], fun)}
    end)
  end

  defp first_route_host(%SettingsForm{routes: [%{"host" => host} | _rest]}), do: host
  defp first_route_host(%SettingsForm{}), do: ""

  # The port a new route points at: the first one already proxied, else the first port
  # at all. A route added with no backend is the one mistake this table can silently
  # make, because an empty select posts nothing.
  defp default_route_port(%SettingsForm{ports: ports}) do
    port =
      Enum.find(ports, &(&1["exposure"] == "proxy")) || List.first(ports)

    to_string(port && port["internal"])
  end

  # Read from the CLUSTER rather than from our conventions: Swarm matches the kind
  # byte-for-byte against daemon.json, so offering a guess would be offering a task
  # that hangs pending.
  defp advertised_gpu_kinds do
    case Homelab.Infrastructure.GpuFacts.advertised_kinds() do
      {:ok, kinds} -> kinds
      {:error, _reason} -> []
    end
  end

  defp apply_config(deployment, attrs, stack? \\ false) do
    with {:ok, updated} <- Deployments.update_deployment(deployment, attrs),
         {:ok, release} <- reconverge(updated, stack?) do
      {:ok, Deployments.get_deployment!(updated.id), release}
    else
      # The changeset's OWN message, not a generic stand-in. Every refusal reachable from
      # this form was written to say what is wrong and what to do instead — `Netns` alone
      # has ten — and collapsing them all to "Could not save the configuration." is why
      # choosing a network container read as a broken feature rather than a refused one.
      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, HomelabWeb.ChangesetErrors.to_sentence(changeset)}

      # The config IS saved — `update_deployment/2` committed before the plan was
      # refused — so this must not read as a failed save, or the operator retypes an
      # edit the row already holds. Both saga entry points can refuse this way, and it
      # is the ordinary outcome of saving twice in a row while the first release runs.
      # A second save normally SUPERSEDES the release still in flight, so reaching here
      # means it was one of the few that cannot be handed over: an import moving data, a
      # rollback undoing itself, or a deploy anchored on another deployment in this
      # stack. The edit is committed either way — say which of the two happened, or the
      # operator retypes something the row already holds.
      {:error, {:release_in_flight, _id}} ->
        {:error,
         "Saved, but not applied yet: this deployment is being driven by a release that " <>
           "cannot be handed over — an import, a rollback, or a deploy anchored on " <>
           "another deployment in its stack. Re-run the deploy once that one finishes."}

      {:error, :release_active} ->
        {:error,
         "Saved, but not applied yet: a release is already running for this stack. " <>
           "Re-run the deploy once it finishes."}

      {:error, reason} ->
        {:error, "Saved, but the release could not be planned: #{inspect(reason)}"}
    end
  end

  # Both branches plan a release; they differ only in what the release covers.
  #
  # A lone container converges through a release of its own. A network-namespace group
  # cannot: re-creating one member mints a new container id that the others are pinned
  # to, so the group goes round together as one ordered release.
  #
  # The `false` branch used to be `Deployments.recreate_deployment/1`, which deployed
  # imperatively in this process — right result, no release row, so the Releases tab
  # stayed empty for every version bump and every network edit.
  defp reconverge(deployment, true),
    do: Deployments.redeploy_netns_stack(deployment, plan: %{"kind" => "reconfigure"})

  defp reconverge(deployment, false), do: Deployments.reconverge_release(deployment)

  # True when this save touches a network-namespace group at all — either this
  # deployment is joining/leaving one, or it is the donor others are already inside.
  defp netns_member?(deployment, new_parent_id) do
    not is_nil(new_parent_id) or not is_nil(deployment.network_parent_id) or
      Homelab.Deployments.Netns.donor?(deployment)
  end

  # Deployments in the same space that could host this one's network namespace.
  # Excludes itself, anything already inside another namespace (chains are not
  # supported) and host-networked containers (which have no namespace to share).
  defp netns_candidates(deployment) do
    Deployments.list_deployments()
    |> Enum.filter(fn candidate ->
      candidate.id != deployment.id and
        candidate.tenant_id == deployment.tenant_id and
        is_nil(candidate.network_parent_id) and
        not Access.host_network_mode?(candidate)
    end)
    |> Enum.sort_by(& &1.app_template.name)
  end

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

  # Which radio starts checked: the port Traefik will ACTUALLY forward to. A stored
  defp settings_saved_flash(updated, stack?) do
    base = "Settings saved — #{release_started_flash(stack?)}"

    case guarded_publish_conflicts(updated) do
      [] ->
        base

      [port] ->
        base <>
          " Port #{port} was not published to the host: Traefik routes to it, and this app's" <>
          " access check only runs on the proxy."

      ports ->
        base <>
          " Ports #{Enum.join(ports, ", ")} were not published to the host: Traefik routes to" <>
          " them, and this app's access check only runs on the proxy."
    end
  end

  # The ports the operator asked to publish that `SpecBuilder.build_ports/1` will refuse.
  #
  # The checkbox already blocks the routed port, so in practice this catches the case the
  # editor cannot see live: a port that is the backend of an extra path route or an
  # additional domain. Read off the SAVED deployment, so the routes and hosts are the ones
  # actually stored rather than whatever the form assigns had lagged to, and asked of the
  # same function the spec builder uses so the message can't claim a different rule.
  defp guarded_publish_conflicts(deployment) do
    if Access.protected?(deployment) do
      guarded = SpecBuilder.guarded_backend_ports(deployment)

      deployment
      |> Access.effective_ports()
      |> Enum.filter(&(&1["published"] == true))
      |> Enum.map(&to_string(&1["internal"]))
      |> Enum.filter(&MapSet.member?(guarded, &1))
      |> Enum.uniq()
    else
      []
    end
  end

  # Volume rows, as the Volumes tab holds them. `target` is the shape a spec-built
  # volume carries; `container_path` the shape the template and the override carry.
  # Both go through VolumeSpec. This used to carry its own inference ("a volume with a
  # source is a bind unless it says otherwise") which contradicted SpecBuilder's ("a
  # volume with a source is a VOLUME unless it says otherwise") -- so an adopted named
  # volume displayed as a folder mount, and the two disagreed about what was mounted.
  defp volume_rows(volumes), do: VolumeSpec.parse_rows(List.wrap(volumes))

  defp volume_rows_from_params(params), do: VolumeSpec.parse_rows(params)

  # What is actually mounted at a row: the name it carries, or — for a managed row that
  # carries none — the name SpecBuilder will derive, through SpecBuilder itself so the
  # page cannot show a name the deployment does not use.
  defp volume_source_name(vol, deployment) do
    case vol["source"] do
      source when is_binary(source) and source != "" -> source
      _ -> derived_volume_name(deployment, vol["container_path"] || vol["path"]) || "—"
    end
  end

  # The placeholder is the derived name rather than a generic hint, so a blank field
  # says which volume leaving it blank will mount.
  defp volume_source_placeholder(%{"type" => "bind"}, _deployment),
    do: "/home/you/.homelab/app/data"

  defp volume_source_placeholder(vol, deployment) do
    derived_volume_name(deployment, vol["container_path"]) || "named after this deployment"
  end

  defp derived_volume_name(%{tenant: %{slug: tenant_slug}, app_template: %{slug: app_slug}}, path)
       when is_binary(path) and path != "" do
    SpecBuilder.volume_name(tenant_slug, app_slug, path)
  end

  defp derived_volume_name(_deployment, _path), do: nil

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

  defp format_bytes(bytes) when is_integer(bytes) and bytes >= 1_073_741_824,
    do: "#{Float.round(bytes / 1_073_741_824, 1)} GB"

  defp format_bytes(bytes) when is_integer(bytes),
    do: "#{Float.round(bytes / 1_048_576, 1)} MB"

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
  defp pill_classes(:superseded), do: "bg-base-200 text-base-content/50"
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
  defp format_status(:superseded), do: "Superseded"
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
  # The step a release STOPPED at — which is not the same as "a step that failed".
  #
  # An advisory step (`:verify_public_url`) records a failure and the saga carries on, so
  # a release can settle `:running` with a failed step on it. Reporting that as "Deploy
  # stopped at ..." would be flatly wrong: the deploy finished and the container is up;
  # only the URL check did not pass, which the release card already shows in place.
  defp failed_step(%Homelab.Deployments.Release{status: status}) when status == :running,
    do: nil

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

  # The interaction half of every action button on this page: the cursor, the press, the
  # in-flight state. Held in one place because it is the half that was missing — the
  # buttons carried their colour and nothing else, so a click that enqueued an Oban job
  # and returned looked exactly like a click that did nothing, on a default arrow cursor.
  #
  # `phx-click-loading` is LiveView's own class, applied for as long as the event is
  # unacknowledged (the variant is declared in app.css). It covers the round trip; the
  # release card that appears afterwards covers the work.
  defp action_button do
    "rounded-lg font-medium cursor-pointer transition-all active:scale-[0.97] " <>
      "phx-click-loading:opacity-60 phx-click-loading:cursor-wait phx-click-loading:scale-[0.97] " <>
      "disabled:cursor-not-allowed disabled:opacity-50 disabled:active:scale-100"
  end

  attr :release, :any, required: true
  attr :size, :string, required: true

  # Rendered in both states rather than hidden while a release runs. The button used to
  # carry `:if={can_redeploy?(...)}`, so pressing it made it disappear — which is a
  # signal, but not one that says a release started, and it reads identically to the
  # control having been removed. Disabled-and-labelled says which.
  defp redeploy_button(assigns) do
    ~H"""
    <button
      type="button"
      phx-click="redeploy"
      disabled={not can_redeploy?(@release)}
      data-confirm="Re-run the deployment steps for this stack from the start?"
      class={[
        action_button(),
        @size,
        "shrink-0 inline-flex items-center gap-1.5 bg-primary text-primary-content hover:bg-primary/90"
      ]}
    >
      <%= if can_redeploy?(@release) do %>
        <.icon name="hero-arrow-path" class="size-4" /> Re-run deploy
      <% else %>
        <.icon name="hero-arrow-path" class="size-4 animate-spin" />
        {release_progress(@release)}
      <% end %>
    </button>
    """
  end

  # "Deploying 3/7 · await health" beats a spinner: the steps are already in the release
  # and the operator's next question is always which one is taking this long. Falls back
  # to the release's own status once every step is done but the saga has not settled.
  defp release_progress(%Homelab.Deployments.Release{} = release) do
    steps = Enum.sort_by(release.steps, & &1.position)
    done = Enum.count(steps, &(&1.status in [:completed, :skipped]))

    case next_pending_or_running(steps) do
      nil -> format_status(release.status)
      step -> "#{done}/#{length(steps)} · #{humanize_step(step.type)}"
    end
  end

  defp release_progress(_release), do: "Working…"

  defp next_pending_or_running(steps) do
    Enum.find(steps, &(&1.status == :running)) || Enum.find(steps, &(&1.status == :pending))
  end

  # What each step MEANS, rather than its type spelled with spaces. The timeline is the
  # one place an operator reads a deploy, and "publish ingress" is the clearest example of
  # why the identifier is not the label: it names the mechanism (attach the workload to
  # the ingress network) while the reader is asking about the outcome, and the outcome it
  # delivers is a precondition of being reachable rather than being reachable — which is
  # what `:verify_public_url` was added to actually assert.
  defp humanize_step(:ensure_ingress_proxy), do: "Reverse proxy running"
  defp humanize_step(:provision_credentials), do: "Credentials generated"
  defp humanize_step(:dependency_container), do: "Dependency container started"
  defp humanize_step(:ensure_datastore_grants), do: "Database access granted"
  defp humanize_step(:app_container), do: "Container created"
  defp humanize_step(:netns_child_container), do: "Container created in shared network"
  defp humanize_step(:await_health), do: "Container healthy"
  defp humanize_step(:sync_domain), do: "Domain claimed"
  defp humanize_step(:publish_dns), do: "DNS records published"
  defp humanize_step(:publish_ingress), do: "Attached to the reverse proxy"
  defp humanize_step(:verify_public_url), do: "Answering at its URL"
  defp humanize_step(:network), do: "Network created"
  defp humanize_step(:backup_verify), do: "Backup verified"
  defp humanize_step(:quiesce_old), do: "Existing container paused"
  defp humanize_step(:migrate_volume), do: "Data copied"
  defp humanize_step(:resume_old), do: "Existing container resumed"
  defp humanize_step(:adopt_credentials), do: "Credentials imported"
  defp humanize_step(:adopt_volume), do: "Volume adopted"
  defp humanize_step(:adopt_container), do: "Container adopted"
  defp humanize_step(:verify_integrity), do: "Copied data verified"
  defp humanize_step(type), do: type |> to_string() |> String.replace("_", " ")

  # The steps in lifecycle order, grouped by stage. Releases planned before stages
  # existed carry none, and render as one flat list.
  defp staged_steps(release) do
    release.steps
    |> Enum.sort_by(& &1.position)
    |> Enum.group_by(& &1.stage)
    |> in_stage_order()
  end

  defp in_stage_order(%{nil => steps} = grouped) when map_size(grouped) == 1,
    do: [{nil, steps}]

  defp in_stage_order(grouped),
    do: Enum.flat_map(ReleaseStep.stages() ++ [nil], &stage_group(grouped, &1))

  defp stage_group(grouped, stage) do
    case grouped[stage] do
      nil -> []
      steps -> [{stage, steps}]
    end
  end

  defp stage_label(:prepare), do: "Prepare"
  defp stage_label(:dependencies), do: "Dependencies"
  defp stage_label(:workload), do: "Workload"
  defp stage_label(:namespace), do: "Shared network namespace"
  defp stage_label(:naming), do: "Naming"
  defp stage_label(:reachability), do: "Reachability"
  defp stage_label(:verification), do: "Verification"
  defp stage_label(_stage), do: "Steps"

  # A step's message is styled by what KIND of message it is: a failure, a condition
  # that did not hold, or a note from a step that succeeded anyway.
  defp reason_classes("error"), do: "text-error"
  defp reason_classes("note"), do: "text-warning"
  defp reason_classes(_skipped), do: "text-base-content/50"

  # What KIND of event this release was, which its steps cannot say: a config save and a
  # first deploy of an app with no companions plan an identical list. Only the planner
  # knew, so it writes `plan["kind"]` and this reads it back.
  #
  # Unlabelled means a plain deploy — every release planned before this badge existed,
  # plus `deploy_release/2` itself, which needs no badge because it is the default thing
  # a release is.
  defp release_kind(%{plan: %{"kind" => "reconfigure"}}),
    do: {"Config change", "bg-info/10 text-info"}

  defp release_kind(%{plan: %{"kind" => "adoption"}}),
    do: {"Adoption", "bg-secondary/10 text-secondary"}

  defp release_kind(_release), do: {"Deploy", "bg-base-content/5 text-base-content/50"}

  # One release: header (status + kind + time + lease), any release-level error, then the
  # ordered steps with per-step status and error.
  attr :release, :map, required: true

  defp release_card(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden">
      <div class="flex items-center justify-between px-4 py-3 border-b border-base-content/5">
        <div class="flex items-center gap-3">
          <.status_pill status={@release.status} />
          <% {kind_label, kind_class} = release_kind(@release) %>
          <span class={["text-[11px] font-medium px-2 py-0.5 rounded-full", kind_class]}>
            {kind_label}
          </span>
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
        class={[
          "px-4 py-2 text-xs border-b",
          if(@release.status == :superseded,
            do: "bg-base-200/50 text-base-content/50 border-base-content/5",
            else: "bg-error/5 text-error border-error/10"
          )
        ]}
      >
        {@release.error_message}
      </div>

      <div :for={{stage, steps} <- staged_steps(@release)}>
        <p
          :if={stage}
          class="px-4 pt-3 pb-1 text-[10px] font-semibold uppercase tracking-wider text-base-content/40"
        >
          {stage_label(stage)}
        </p>
        <ul class="divide-y divide-base-content/5">
          <li :for={step <- steps} class="flex items-start gap-3 px-4 py-2.5">
            <% {icon, icon_class} = step_icon(step.status) %>
            <.icon name={icon} class={["size-4 mt-0.5 shrink-0", icon_class]} />
            <div class="min-w-0">
              <p class="text-sm text-base-content">
                {humanize_step(step.type)}
                <span class="text-xs text-base-content/40">· {format_status(step.status)}</span>
              </p>
              <p
                :if={step.reason_message}
                class={["text-xs mt-0.5 break-words", reason_classes(step.reason_type)]}
              >
                {step.reason_message}
              </p>
            </div>
          </li>
        </ul>
      </div>
    </div>
    """
  end
end
