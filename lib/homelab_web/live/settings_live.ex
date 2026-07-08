defmodule HomelabWeb.SettingsLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Settings
  alias Homelab.Accounts
  alias Homelab.Docker.Client, as: DockerClient

  @sections [
    {"general", "General", "hero-cog-6-tooth"},
    {"authentication", "Authentication", "hero-key"},
    {"infrastructure", "Infrastructure", "hero-server-stack"},
    {"dns", "DNS & Domains", "hero-globe-alt"},
    {"registry", "Registry", "hero-cube"},
    {"registries", "Registries", "hero-archive-box"},
    {"catalog", "Catalog", "hero-rectangle-stack"},
    {"import", "Import", "hero-arrow-down-tray"},
    {"users", "Users", "hero-user-group"},
    {"danger_zone", "Danger Zone", "hero-exclamation-triangle"}
  ]

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()

    socket =
      socket
      |> assign(:page_title, "Settings")
      |> assign(:tenants, tenants)
      |> assign(:sections, @sections)
      |> assign(:active_section, "general")
      |> load_section_data("general")

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    section = params["section"] || "general"
    section = if section in Enum.map(@sections, &elem(&1, 0)), do: section, else: "general"

    {:noreply,
     socket
     |> assign(:active_section, section)
     |> load_section_data(section)}
  end

  @impl true
  def handle_event("switch_section", %{"section" => section}, socket) do
    {:noreply,
     socket
     |> assign(:active_section, section)
     |> push_patch(to: ~p"/settings?section=#{section}")
     |> load_section_data(section)}
  end

  def handle_event(
        "save_general",
        %{"general" => %{"instance_name" => name, "base_domain" => domain}},
        socket
      ) do
    Settings.set("instance_name", name)
    Settings.set("base_domain", domain)

    {:noreply,
     socket
     |> assign(:instance_name, name)
     |> assign(:base_domain, domain)
     |> put_flash(:info, "General settings saved!")}
  end

  def handle_event("save_registry", params, socket) do
    registry_params = params["registry"] || %{}
    registry_name = registry_params["registry"] || registry_params["registry_name"]

    case registry_name do
      "ghcr" ->
        token = registry_params["ghcr_token"] || ""
        if token != "", do: Settings.set("ghcr_token", token, encrypt: true)

      "ecr" ->
        key = registry_params["ecr_access_key"] || ""
        secret = registry_params["ecr_secret_key"] || ""
        region = registry_params["ecr_region"] || ""
        if key != "", do: Settings.set("ecr_access_key", key, encrypt: true)
        if secret != "", do: Settings.set("ecr_secret_key", secret, encrypt: true)
        if region != "", do: Settings.set("ecr_region", region)

      "docker_hub" ->
        token = registry_params["docker_hub_token"] || ""
        if token != "", do: Settings.set("docker_hub_token", token, encrypt: true)

      _ ->
        :ok
    end

    {:noreply,
     socket
     |> load_section_data("registries")
     |> put_flash(:info, "Registry settings saved!")}
  end

  def handle_event("save_self_hosted_registry", %{"registry" => params}, socket) do
    if (params["username"] || "") != "", do: Settings.set("registry_username", params["username"])

    if (params["password"] || "") != "",
      do: Settings.set("registry_password", params["password"], encrypt: true)

    if (params["host_ip"] || "") != "", do: Settings.set("registry_host_ip", params["host_ip"])
    Settings.set("registry_mirror_enabled", params["mirror_enabled"] || "false")

    {:noreply,
     socket
     |> load_section_data("registry")
     |> put_flash(:info, "Registry settings saved.")}
  end

  def handle_event("enable_registry", _params, socket) do
    Settings.set("registry_enabled", "true")

    socket =
      case Homelab.Infrastructure.Registry.ensure_registry() do
        {:ok, _} ->
          if Settings.get("registry_mirror_enabled") == "true" do
            _ = Homelab.Infrastructure.Registry.ensure_registry_proxy()
          end

          put_flash(socket, :info, "Registry provisioned. It may take a moment for TLS to issue.")

        {:error, :missing_credentials} ->
          Settings.set("registry_enabled", "false")
          put_flash(socket, :error, "Set a username and password before enabling the registry.")

        {:error, reason} ->
          Settings.set("registry_enabled", "false")
          put_flash(socket, :error, "Failed to provision registry: #{inspect(reason)}")
      end

    {:noreply, load_section_data(socket, "registry")}
  end

  def handle_event("disable_registry", _params, socket) do
    Settings.set("registry_enabled", "false")
    _ = Homelab.Infrastructure.Registry.teardown()

    {:noreply,
     socket
     |> load_section_data("registry")
     |> put_flash(:info, "Registry stopped. Data volumes were kept.")}
  end

  def handle_event("run_discovery", _params, socket) do
    case Homelab.Deployments.AdoptionPlanner.review() do
      {:ok, services} ->
        {:noreply,
         socket
         |> assign(:import_services, services)
         |> assign(:import_selected, MapSet.new(Enum.map(services, & &1.name)))
         |> assign(:import_plan, nil)
         |> assign(:import_error, nil)}

      {:error, reason} ->
        {:noreply,
         socket
         |> assign(:import_services, [])
         |> assign(:import_error, "Discovery failed: #{inspect(reason)}")}
    end
  end

  def handle_event("toggle_import_service", %{"name" => name}, socket) do
    selected = socket.assigns.import_selected

    selected =
      if MapSet.member?(selected, name),
        do: MapSet.delete(selected, name),
        else: MapSet.put(selected, name)

    # Selection changed — any previewed plan is now stale.
    {:noreply, assign(socket, import_selected: selected, import_plan: nil)}
  end

  def handle_event("preview_plan", _params, socket) do
    selected =
      (socket.assigns.import_services || [])
      |> Enum.filter(&MapSet.member?(socket.assigns.import_selected, &1.name))

    plan = Homelab.Deployments.AdoptionPlanner.build_plan(selected)
    {:noreply, assign(socket, :import_plan, plan)}
  end

  def handle_event("save_orchestrator", %{"driver" => driver_id}, socket) do
    Settings.set("orchestrator", driver_id)

    {:noreply,
     socket
     |> assign(:selected_orchestrator, driver_id)
     |> put_flash(:info, "Orchestrator updated!")}
  end

  def handle_event("save_gateway", %{"driver" => driver_id}, socket) do
    Settings.set("gateway", driver_id)

    {:noreply,
     socket
     |> assign(:selected_gateway, driver_id)
     |> put_flash(:info, "Gateway updated!")}
  end

  def handle_event("rerun_setup", _params, socket) do
    Settings.delete("setup_completed")
    {:noreply, push_navigate(socket, to: ~p"/setup")}
  end

  def handle_event("save_sweep_mode", %{"mode" => mode}, socket)
      when mode in ~w(sever_only armed paused) do
    {:ok, _} = Settings.set("reconciler_sweep_mode", mode, category: "reconciler")

    {:noreply,
     socket
     |> put_flash(:info, "Orphan sweep mode set to #{sweep_mode_label(mode)}.")
     |> load_section_data("danger_zone")}
  end

  def handle_event("save_sweep_mode", _params, socket) do
    {:noreply, put_flash(socket, :error, "Unknown sweep mode.")}
  end

  def handle_event("toggle_catalog", %{"id" => id}, socket) do
    enabled = enabled_catalog_ids()
    updated = if id in enabled, do: List.delete(enabled, id), else: [id | enabled]
    {:ok, _} = Settings.set("enabled_catalogs", Jason.encode!(updated))

    {:noreply,
     socket
     |> put_flash(:info, "Catalog sources updated.")
     |> load_section_data("catalog")}
  end

  def handle_event("remove_orphan", %{"id" => id}, socket) do
    socket =
      case Homelab.Services.Reconciler.remove_orphan(id) do
        :ok ->
          put_flash(socket, :info, "Orphaned container removed.")

        {:error, :not_orphaned} ->
          put_flash(socket, :error, "That container is no longer tracked.")

        {:error, reason} ->
          put_flash(socket, :error, "Could not remove container: #{inspect(reason)}")
      end

    {:noreply, load_section_data(socket, "danger_zone")}
  end

  def handle_event("save_dns", %{"dns" => params}, socket) do
    if params["cloudflare_api_token"] && params["cloudflare_api_token"] != "" do
      Settings.set("cloudflare_api_token", params["cloudflare_api_token"], encrypt: true)
    end

    if params["registrar"] && params["registrar"] != "" do
      Settings.set("registrar", params["registrar"])
    end

    if params["public_dns_provider"] && params["public_dns_provider"] != "" do
      Settings.set("public_dns_provider", params["public_dns_provider"])
    end

    if params["internal_dns_provider"] && params["internal_dns_provider"] != "" do
      Settings.set("internal_dns_provider", params["internal_dns_provider"])
    end

    if params["unifi_host"] && params["unifi_host"] != "" do
      Settings.set("unifi_host", params["unifi_host"])
    end

    if params["unifi_api_key"] && params["unifi_api_key"] != "" do
      Settings.set("unifi_api_key", params["unifi_api_key"], encrypt: true)
    end

    if params["unifi_site"] && params["unifi_site"] != "" do
      Settings.set("unifi_site", params["unifi_site"])
    end

    if params["unifi_api_version"] && params["unifi_api_version"] != "" do
      Settings.set("unifi_api_version", params["unifi_api_version"])
    end

    Settings.set("unifi_skip_tls_verify", params["unifi_skip_tls_verify"] || "false")

    if params["pihole_url"] && params["pihole_url"] != "" do
      Settings.set("pihole_url", params["pihole_url"])
    end

    if params["pihole_api_key"] && params["pihole_api_key"] != "" do
      Settings.set("pihole_api_key", params["pihole_api_key"], encrypt: true)
    end

    if params["namecheap_api_user"] && params["namecheap_api_user"] != "" do
      Settings.set("namecheap_api_user", params["namecheap_api_user"])
    end

    if params["namecheap_api_key"] && params["namecheap_api_key"] != "" do
      Settings.set("namecheap_api_key", params["namecheap_api_key"], encrypt: true)
    end

    if params["namecheap_client_ip"] && params["namecheap_client_ip"] != "" do
      Settings.set("namecheap_client_ip", params["namecheap_client_ip"])
    end

    Settings.set("namecheap_use_sandbox", params["namecheap_use_sandbox"] || "false")

    {:noreply,
     socket
     |> load_section_data("dns")
     |> put_flash(:info, "DNS settings saved!")}
  end

  def handle_event("update_user_role", %{"user_id" => user_id, "role" => role}, socket) do
    case Accounts.get_user(String.to_integer(user_id)) do
      nil ->
        {:noreply, put_flash(socket, :error, "User not found")}

      user ->
        case Accounts.update_user(user, %{role: String.to_existing_atom(role)}) do
          {:ok, _} ->
            {:noreply,
             socket
             |> load_section_data("users")
             |> put_flash(:info, "User role updated!")}

          {:error, _} ->
            {:noreply, put_flash(socket, :error, "Failed to update role")}
        end
    end
  end

  defp load_section_data(socket, "general") do
    params = %{
      "instance_name" => Settings.get("instance_name", ""),
      "base_domain" => Settings.get("base_domain", "")
    }

    assign(socket, :instance_name, params["instance_name"])
    |> assign(:base_domain, params["base_domain"])
    |> assign(:general_form, to_form(params, as: :general))
  end

  defp load_section_data(socket, "authentication") do
    assign(socket, :oidc_issuer, Settings.get("oidc_issuer", ""))
    |> assign(:oidc_client_id, Settings.get("oidc_client_id", ""))
    |> assign(
      :oidc_client_secret_placeholder,
      if(Settings.get("oidc_client_secret"), do: "••••••••", else: "")
    )
  end

  defp load_section_data(socket, "infrastructure") do
    socket_path = DockerClient.socket_path()

    version_info =
      case DockerClient.get("/version") do
        {:ok, body} -> {:ok, body}
        {:error, reason} -> {:error, reason}
      end

    current_orchestrator = Homelab.Config.orchestrator()

    current_id =
      if current_orchestrator && function_exported?(current_orchestrator, :driver_id, 0),
        do: current_orchestrator.driver_id(),
        else: nil

    current_gateway = Homelab.Config.gateway()

    current_gateway_id =
      if current_gateway && function_exported?(current_gateway, :driver_id, 0),
        do: current_gateway.driver_id(),
        else: nil

    assign(socket, :docker_socket_path, socket_path)
    |> assign(:docker_version_info, version_info)
    |> assign(:orchestrators, Homelab.Config.orchestrators())
    |> assign(:selected_orchestrator, current_id)
    |> assign(:gateways, Homelab.Config.gateways())
    |> assign(:selected_gateway, current_gateway_id)
  end

  defp load_section_data(socket, "dns") do
    socket
    |> assign(:cloudflare_token_set?, Settings.get("cloudflare_api_token") != nil)
    |> assign(:selected_registrar, Settings.get("registrar"))
    |> assign(:selected_public_dns, Settings.get("public_dns_provider"))
    |> assign(:selected_internal_dns, Settings.get("internal_dns_provider"))
    |> assign(:unifi_host, Settings.get("unifi_host", ""))
    |> assign(:unifi_api_key_set?, Settings.get("unifi_api_key") != nil)
    |> assign(:unifi_site, Settings.get("unifi_site", "default"))
    |> assign(:unifi_api_version, Settings.get("unifi_api_version", "auto"))
    |> assign(:unifi_skip_tls_verify, Settings.get("unifi_skip_tls_verify", "false"))
    |> assign(:pihole_url, Settings.get("pihole_url", ""))
    |> assign(:pihole_api_key_set?, Settings.get("pihole_api_key") != nil)
    |> assign(:namecheap_api_user, Settings.get("namecheap_api_user", ""))
    |> assign(:namecheap_api_key_set?, Settings.get("namecheap_api_key") != nil)
    |> assign(:namecheap_client_ip, Settings.get("namecheap_client_ip", ""))
    |> assign(:namecheap_use_sandbox, Settings.get("namecheap_use_sandbox", "false"))
    |> assign(:registrar_options, Homelab.Config.registrars())
    |> assign(:dns_provider_options, Homelab.Config.dns_providers())
  end

  defp load_section_data(socket, "registries") do
    assign(socket, :ghcr_token_set?, Settings.get("ghcr_token") != nil)
    |> assign(:ecr_configured?, Settings.get("ecr_access_key") != nil)
    |> assign(:docker_hub_token_set?, Settings.get("docker_hub_token") != nil)
  end

  defp load_section_data(socket, "registry") do
    base_domain = Homelab.Config.base_domain()

    assign(socket, :registry_enabled?, Settings.get("registry_enabled") == "true")
    |> assign(:registry_username, Settings.get("registry_username", ""))
    |> assign(:registry_password_set?, Settings.get("registry_password") != nil)
    |> assign(:registry_mirror_enabled?, Settings.get("registry_mirror_enabled") == "true")
    |> assign(:registry_host_ip, Settings.get("registry_host_ip", ""))
    |> assign(:registry_host, "registry.#{base_domain}")
    |> assign(:registry_mirror_host, "proxy-registry.#{base_domain}")
  end

  defp load_section_data(socket, "import") do
    socket
    |> assign_new(:import_services, fn -> nil end)
    |> assign_new(:import_selected, fn -> MapSet.new() end)
    |> assign_new(:import_plan, fn -> nil end)
    |> assign_new(:import_error, fn -> nil end)
  end

  defp load_section_data(socket, "users") do
    assign(socket, :users, Accounts.list_users())
  end

  defp load_section_data(socket, "catalog") do
    all =
      Enum.map(Homelab.Config.all_application_catalogs(), fn mod ->
        %{id: mod.driver_id(), name: mod.display_name(), description: mod.description()}
      end)

    socket
    |> assign(:all_catalogs, all)
    |> assign(:enabled_catalogs, enabled_catalog_ids())
  end

  defp load_section_data(socket, "danger_zone") do
    socket
    |> assign(:sweep_mode, Settings.get("reconciler_sweep_mode", "sever_only"))
    |> assign(:orphans, Homelab.Services.Reconciler.list_orphans())
  end

  defp load_section_data(socket, _), do: socket

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
        <div class="relative overflow-hidden rounded-lg bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-8">
          <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl"></div>
          <div class="relative">
            <div class="flex items-center gap-3 mb-2">
              <div class="w-10 h-10 rounded-lg bg-primary/20 flex items-center justify-center">
                <.icon name="hero-cog-6-tooth-solid" class="size-5 text-primary" />
              </div>
              <h1 class="text-2xl font-bold text-base-content tracking-tight">Settings</h1>
            </div>
            <p class="text-sm text-base-content/50 max-w-lg leading-relaxed mt-1">
              Configure your Homelab instance, authentication, and integrations.
            </p>
          </div>
        </div>

        <div class="flex flex-col lg:flex-row gap-8">
          <%!-- Sidebar tabs --%>
          <aside class="lg:w-56 flex-shrink-0">
            <nav class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
              <button
                :for={{id, label, icon} <- @sections}
                type="button"
                phx-click="switch_section"
                phx-value-section={id}
                class={[
                  "w-full flex items-center gap-3 px-4 py-3 text-left text-sm font-medium transition-colors cursor-pointer border-b border-base-content/[0.04] last:border-b-0",
                  @active_section == id && "bg-primary/10 text-primary",
                  @active_section != id &&
                    "text-base-content/60 hover:bg-base-content/[0.03] hover:text-base-content"
                ]}
              >
                <.icon name={icon} class="size-5" />
                {label}
              </button>
            </nav>
          </aside>

          <%!-- Section content --%>
          <div class="flex-1 min-w-0">
            <div class="rounded-lg border border-base-content/[0.06] bg-base-100 overflow-hidden">
              {section_content(assigns)}
            </div>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  defp section_content(assigns) do
    case assigns.active_section do
      "general" -> render_general(assigns)
      "authentication" -> render_authentication(assigns)
      "infrastructure" -> render_infrastructure(assigns)
      "dns" -> render_dns(assigns)
      "registry" -> render_registry(assigns)
      "registries" -> render_registries(assigns)
      "catalog" -> render_catalog(assigns)
      "import" -> render_import(assigns)
      "users" -> render_users(assigns)
      "danger_zone" -> render_danger_zone(assigns)
      _ -> render_general(assigns)
    end
  end

  defp render_general(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-base-content mb-4">General</h2>
      <.form
        for={@general_form}
        id="general-form"
        phx-submit="save_general"
        class="space-y-4 max-w-md"
      >
        <div>
          <.input
            name="general[instance_name]"
            value={@instance_name}
            type="text"
            label="Instance Name"
            placeholder="My Homelab"
          />
        </div>
        <div>
          <.input
            name="general[base_domain]"
            value={@base_domain}
            type="text"
            label="Base Domain"
            placeholder="lab.example.com"
          />
        </div>
        <.button
          type="submit"
          label="Save"
          class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
        />
      </.form>
    </div>
    """
  end

  defp render_authentication(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-base-content mb-4">Authentication</h2>
      <div class="space-y-4 max-w-md">
        <div>
          <label class="block text-sm font-medium text-base-content/70 mb-1.5">OIDC Issuer URL</label>
          <input
            type="url"
            value={@oidc_issuer}
            readonly
            class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content/70 py-2.5 px-3"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-base-content/70 mb-1.5">Client ID</label>
          <input
            type="text"
            value={@oidc_client_id}
            readonly
            class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content/70 py-2.5 px-3"
          />
        </div>
        <div>
          <label class="block text-sm font-medium text-base-content/70 mb-1.5">Client Secret</label>
          <input
            type="password"
            value={@oidc_client_secret_placeholder}
            readonly
            placeholder="Configured"
            class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content/70 py-2.5 px-3"
          />
        </div>
        <div class="flex gap-3">
          <button
            type="button"
            class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
          >
            Test Connection
          </button>
          <button
            type="button"
            class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
          >
            Re-run Discovery
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_infrastructure(assigns) do
    ~H"""
    <div class="p-4 space-y-5">
      <div>
        <h2 class="text-lg font-semibold text-base-content mb-4">Docker Connection</h2>
        <div class="space-y-4 max-w-md">
          <div>
            <label class="block text-sm font-medium text-base-content/70 mb-1.5">Socket Path</label>
            <input
              type="text"
              value={@docker_socket_path}
              readonly
              class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content/70 py-2.5 px-3 font-mono"
            />
          </div>
          <div>
            <label class="block text-sm font-medium text-base-content/70 mb-1.5">
              Connection Status
            </label>
            <%= case @docker_version_info do %>
              <% {:ok, info} -> %>
                <div class="rounded-lg border border-success/20 bg-success/5 p-4">
                  <div class="flex items-center gap-2 text-success font-medium mb-2">
                    <.icon name="hero-check-circle" class="size-5" />
                    <span>Connected</span>
                  </div>
                  <p class="text-sm text-base-content/70">
                    Version: {info["Version"] || info["ApiVersion"] || "—"}
                  </p>
                </div>
              <% {:error, reason} -> %>
                <div class="rounded-lg border border-error/20 bg-error/5 p-4">
                  <div class="flex items-center gap-2 text-error font-medium">
                    <.icon name="hero-x-mark" class="size-5" />
                    <span>Disconnected</span>
                  </div>
                  <p class="text-sm text-base-content/70 mt-1">{inspect(reason)}</p>
                </div>
            <% end %>
          </div>
        </div>
      </div>

      <div>
        <h2 class="text-lg font-semibold text-base-content mb-2">Container Orchestrator</h2>
        <p class="text-sm text-base-content/50 mb-4">
          Controls how containers are managed and deployed.
        </p>
        <div class="space-y-2 max-w-md">
          <button
            :for={mod <- @orchestrators}
            type="button"
            phx-click="save_orchestrator"
            phx-value-driver={mod.driver_id()}
            class={[
              "w-full text-left rounded-lg border p-4 transition-all cursor-pointer",
              if(@selected_orchestrator == mod.driver_id(),
                do: "border-primary bg-primary/5 ring-1 ring-primary/20",
                else: "border-base-content/10 hover:border-base-content/20 bg-base-100"
              )
            ]}
          >
            <div class="flex items-center gap-3">
              <div class={[
                "w-4 h-4 rounded-full border-2 flex items-center justify-center shrink-0",
                if(@selected_orchestrator == mod.driver_id(),
                  do: "border-primary",
                  else: "border-base-content/20"
                )
              ]}>
                <div
                  :if={@selected_orchestrator == mod.driver_id()}
                  class="w-2 h-2 rounded-full bg-primary"
                >
                </div>
              </div>
              <div>
                <p class="text-sm font-medium text-base-content">{mod.display_name()}</p>
                <p class="text-xs text-base-content/50 mt-0.5">{mod.description()}</p>
              </div>
            </div>
          </button>
        </div>
      </div>

      <div>
        <h2 class="text-lg font-semibold text-base-content mb-2">Reverse Proxy</h2>
        <p class="text-sm text-base-content/50 mb-4">
          Routes traffic to deployed apps via their domains on ports 80/443.
        </p>
        <div class="space-y-2 max-w-md">
          <button
            :for={mod <- @gateways}
            type="button"
            phx-click="save_gateway"
            phx-value-driver={mod.driver_id()}
            class={[
              "w-full text-left rounded-lg border p-4 transition-all cursor-pointer",
              if(@selected_gateway == mod.driver_id(),
                do: "border-primary bg-primary/5 ring-1 ring-primary/20",
                else: "border-base-content/10 hover:border-base-content/20 bg-base-100"
              )
            ]}
          >
            <div class="flex items-center gap-3">
              <div class={[
                "w-4 h-4 rounded-full border-2 flex items-center justify-center shrink-0",
                if(@selected_gateway == mod.driver_id(),
                  do: "border-primary",
                  else: "border-base-content/20"
                )
              ]}>
                <div
                  :if={@selected_gateway == mod.driver_id()}
                  class="w-2 h-2 rounded-full bg-primary"
                >
                </div>
              </div>
              <div>
                <p class="text-sm font-medium text-base-content">{mod.display_name()}</p>
                <p class="text-xs text-base-content/50 mt-0.5">{mod.description()}</p>
              </div>
            </div>
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp render_dns(assigns) do
    ~H"""
    <div class="p-4 space-y-6">
      <.form for={%{}} id="dns-settings-form" phx-submit="save_dns" class="space-y-6">
        <%!-- Registrar --%>
        <div>
          <h2 class="text-lg font-semibold text-base-content mb-2">Domain Registrar</h2>
          <p class="text-sm text-base-content/50 mb-4">
            Sync your domain list from a registrar to automatically create DNS zones.
          </p>
          <div class="space-y-4 max-w-md">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Registrar Provider
              </label>
              <select
                name="dns[registrar]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="">None</option>
                <option
                  :for={mod <- @registrar_options}
                  value={mod.driver_id()}
                  selected={@selected_registrar == mod.driver_id()}
                >
                  {mod.display_name()}
                </option>
              </select>
            </div>
            <div :if={@selected_registrar == "cloudflare"}>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Cloudflare API Token
              </label>
              <input
                type="password"
                name="dns[cloudflare_api_token]"
                placeholder={if(@cloudflare_token_set?, do: "••••••••", else: "Enter API token")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
              <p class="text-xs text-base-content/35 mt-1">
                Used for both registrar sync and public DNS record management.
              </p>
            </div>

            <div :if={@selected_registrar == "namecheap"} class="space-y-3">
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  API Username
                </label>
                <input
                  type="text"
                  name="dns[namecheap_api_user]"
                  value={@namecheap_api_user}
                  placeholder="Your Namecheap username"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  API Key
                </label>
                <input
                  type="password"
                  name="dns[namecheap_api_key]"
                  placeholder={
                    if(@namecheap_api_key_set?, do: "••••••••", else: "Enter Namecheap API key")
                  }
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  Whitelisted Client IP
                </label>
                <input
                  type="text"
                  name="dns[namecheap_client_ip]"
                  value={@namecheap_client_ip}
                  placeholder="e.g. 203.0.113.5"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                />
                <p class="text-xs text-base-content/35 mt-1">
                  The IP address whitelisted in your Namecheap API settings.
                </p>
              </div>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  name="dns[namecheap_use_sandbox]"
                  value="true"
                  checked={@namecheap_use_sandbox == "true"}
                  class="rounded border-base-content/20"
                />
                <span class="text-sm text-base-content/60">
                  Use sandbox API (for testing)
                </span>
              </label>
            </div>
          </div>
        </div>

        <hr class="border-base-content/[0.06]" />

        <%!-- Public DNS --%>
        <div>
          <h2 class="text-lg font-semibold text-base-content mb-2">Public DNS Provider</h2>
          <p class="text-sm text-base-content/50 mb-4">
            Manages external DNS records so your domains resolve from the internet.
          </p>
          <div class="space-y-4 max-w-md">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Provider
              </label>
              <select
                name="dns[public_dns_provider]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="">None</option>
                <option
                  :for={mod <- Enum.filter(@dns_provider_options, &(&1.scope() == :public))}
                  value={mod.driver_id()}
                  selected={@selected_public_dns == mod.driver_id()}
                >
                  {mod.display_name()}
                </option>
              </select>
            </div>
            <div :if={@selected_public_dns == "cloudflare" and @selected_registrar != "cloudflare"}>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Cloudflare API Token
              </label>
              <input
                type="password"
                name="dns[cloudflare_api_token]"
                placeholder={if(@cloudflare_token_set?, do: "••••••••", else: "Enter API token")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
              <p class="text-xs text-base-content/35 mt-1">
                Required to create and manage DNS records via the Cloudflare API.
              </p>
            </div>
            <p
              :if={@selected_public_dns == "cloudflare" and @selected_registrar == "cloudflare"}
              class="text-xs text-base-content/50"
            >
              Using the Cloudflare API token configured in the registrar section above.
            </p>
          </div>
        </div>

        <hr class="border-base-content/[0.06]" />

        <%!-- Internal DNS --%>
        <div>
          <h2 class="text-lg font-semibold text-base-content mb-2">Internal DNS Provider</h2>
          <p class="text-sm text-base-content/50 mb-4">
            Manages LAN DNS records so your services resolve internally without hairpin NAT.
          </p>
          <div class="space-y-4 max-w-md">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Provider
              </label>
              <select
                name="dns[internal_dns_provider]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="">None</option>
                <option
                  :for={mod <- Enum.filter(@dns_provider_options, &(&1.scope() == :internal))}
                  value={mod.driver_id()}
                  selected={@selected_internal_dns == mod.driver_id()}
                >
                  {mod.display_name()}
                </option>
              </select>
            </div>

            <%!-- UniFi settings --%>
            <div class="rounded-lg border border-base-content/[0.06] p-4 space-y-3">
              <h3 class="text-sm font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-wifi" class="size-4 text-primary" /> UniFi Network
              </h3>
              <div>
                <label class="block text-xs font-medium text-base-content/60 mb-1">
                  Controller URL
                </label>
                <input
                  type="url"
                  name="dns[unifi_host]"
                  value={@unifi_host}
                  placeholder="https://192.168.1.1"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-base-content/60 mb-1">
                  API Key
                </label>
                <input
                  type="password"
                  name="dns[unifi_api_key]"
                  placeholder={if(@unifi_api_key_set?, do: "••••••••", else: "UniFi API key")}
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div class="grid grid-cols-2 gap-3">
                <div>
                  <label class="block text-xs font-medium text-base-content/60 mb-1">Site</label>
                  <input
                    type="text"
                    name="dns[unifi_site]"
                    value={@unifi_site}
                    placeholder="default"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  />
                </div>
                <div>
                  <label class="block text-xs font-medium text-base-content/60 mb-1">
                    API Version
                  </label>
                  <select
                    name="dns[unifi_api_version]"
                    class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                  >
                    <option value="auto" selected={@unifi_api_version == "auto"}>
                      Auto-detect
                    </option>
                    <option value="new" selected={@unifi_api_version == "new"}>
                      New (10.1+)
                    </option>
                    <option value="legacy" selected={@unifi_api_version == "legacy"}>
                      Legacy (8.x+)
                    </option>
                  </select>
                </div>
              </div>
              <label class="flex items-center gap-2 cursor-pointer">
                <input
                  type="checkbox"
                  name="dns[unifi_skip_tls_verify]"
                  value="true"
                  checked={@unifi_skip_tls_verify == "true"}
                  class="rounded border-base-content/20"
                />
                <span class="text-xs text-base-content/60">
                  Skip TLS verification (for self-signed certs)
                </span>
              </label>
            </div>

            <%!-- Pi-hole settings --%>
            <div class="rounded-lg border border-base-content/[0.06] p-4 space-y-3">
              <h3 class="text-sm font-semibold text-base-content flex items-center gap-2">
                <.icon name="hero-shield-check" class="size-4 text-warning" /> Pi-hole (fallback)
              </h3>
              <div>
                <label class="block text-xs font-medium text-base-content/60 mb-1">
                  Pi-hole URL
                </label>
                <input
                  type="url"
                  name="dns[pihole_url]"
                  value={@pihole_url}
                  placeholder="http://192.168.1.2:8053"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-xs font-medium text-base-content/60 mb-1">
                  API Key
                </label>
                <input
                  type="password"
                  name="dns[pihole_api_key]"
                  placeholder={if(@pihole_api_key_set?, do: "••••••••", else: "Pi-hole API key")}
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
            </div>
          </div>
        </div>

        <div class="pt-2">
          <.button
            type="submit"
            label="Save DNS Settings"
            class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
          />
        </div>
      </.form>
    </div>
    """
  end

  defp render_registry(assigns) do
    ~H"""
    <div class="p-4">
      <div class="flex items-center justify-between mb-4">
        <div>
          <h2 class="text-lg font-semibold text-base-content">Self-hosted registry</h2>
          <p class="text-sm text-base-content/50">
            Push images your Swarm nodes pull locally, plus a Docker Hub pull-through cache.
          </p>
        </div>
        <span class={[
          "text-xs font-semibold rounded-full px-3 py-1",
          if(@registry_enabled?,
            do: "bg-success/15 text-success",
            else: "bg-base-content/10 text-base-content/50"
          )
        ]}>
          {if(@registry_enabled?, do: "Running", else: "Disabled")}
        </span>
      </div>

      <div class="space-y-4">
        <div class="rounded-lg border border-warning/20 bg-warning/5 p-4 text-xs text-base-content/70 space-y-1">
          <p>
            Requires a wildcard <code>*.{Homelab.Config.base_domain()}</code>
            TLS cert (Traefik DNS-01) and the <code>TRAEFIK_DNS_API_TOKEN</code>
            env var.
          </p>
          <p>The pull-through mirror caches <strong>docker.io only</strong> — not GHCR/ECR/quay.</p>
        </div>

        <div class="rounded-lg border border-base-content/[0.06] p-4">
          <h3 class="text-sm font-semibold text-base-content mb-4">Credentials & options</h3>
          <.form
            for={%{}}
            id="self-hosted-registry-form"
            phx-submit="save_self_hosted_registry"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Username</label>
              <input
                type="text"
                name="registry[username]"
                value={@registry_username}
                placeholder="registry user"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Password</label>
              <input
                type="password"
                name="registry[password]"
                placeholder={if(@registry_password_set?, do: "••••••••", else: "set a password")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Host IP (optional — for auto DNS records)
              </label>
              <input
                type="text"
                name="registry[host_ip]"
                value={@registry_host_ip}
                placeholder="203.0.113.10"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <label class="flex items-center gap-2 text-sm text-base-content/70">
              <input
                type="checkbox"
                name="registry[mirror_enabled]"
                value="true"
                checked={@registry_mirror_enabled?}
                class="rounded"
              /> Also run the docker.io pull-through mirror
            </label>
            <.button
              type="submit"
              label="Save"
              class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
            />
          </.form>
        </div>

        <div class="rounded-lg border border-base-content/[0.06] p-4 flex items-center gap-3">
          <button
            :if={!@registry_enabled?}
            type="button"
            phx-click="enable_registry"
            class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
          >
            Enable & provision
          </button>
          <button
            :if={@registry_enabled?}
            type="button"
            phx-click="disable_registry"
            class="px-4 py-2 rounded-lg bg-error/90 text-error-content text-sm font-medium cursor-pointer"
          >
            Disable
          </button>
        </div>

        <div class="rounded-lg border border-base-content/[0.06] p-4 text-xs space-y-3">
          <h3 class="text-sm font-semibold text-base-content">Node operator instructions</h3>
          <div>
            <p class="text-base-content/50 mb-1">Log in and push from any machine:</p>
            <pre class="bg-base-300 rounded p-2 overflow-x-auto">{"docker login #{@registry_host}\ndocker tag myimage #{@registry_host}/myimage:latest\ndocker push #{@registry_host}/myimage:latest"}</pre>
          </div>
          <div>
            <p class="text-base-content/50 mb-1">
              To use the mirror, add to each node's <code>/etc/docker/daemon.json</code>
              (then <code>systemctl restart docker</code>) — this step is manual per node:
            </p>
            <pre class="bg-base-300 rounded p-2 overflow-x-auto">{"{ \"registry-mirrors\": [\"https://#{@registry_mirror_host}\"] }"}</pre>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp render_registries(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-base-content mb-4">Registries</h2>
      <div class="space-y-4">
        <%!-- GHCR --%>
        <div class="rounded-lg border border-base-content/[0.06] p-4">
          <h3 class="text-sm font-semibold text-base-content mb-4">GitHub Container Registry</h3>
          <.form
            for={%{"registry" => "ghcr", "ghcr_token" => ""}}
            id="registry-ghcr-form"
            phx-submit="save_registry"
            class="space-y-4"
          >
            <input type="hidden" name="registry[registry]" value="ghcr" />
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">GitHub PAT</label>
              <input
                type="password"
                name="registry[ghcr_token]"
                placeholder={if(@ghcr_token_set?, do: "••••••••", else: "Enter token")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div class="flex gap-3">
              <.button
                type="submit"
                label="Save"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
              />
              <button
                type="button"
                class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
              >
                Test
              </button>
            </div>
          </.form>
        </div>

        <%!-- ECR --%>
        <div class="rounded-lg border border-base-content/[0.06] p-4">
          <h3 class="text-sm font-semibold text-base-content mb-4">AWS ECR</h3>
          <.form
            for={%{"registry" => "ecr"}}
            id="registry-ecr-form"
            phx-submit="save_registry"
            class="space-y-4"
          >
            <input type="hidden" name="registry[registry]" value="ecr" />
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Access Key</label>
              <input
                type="text"
                name="registry[ecr_access_key]"
                placeholder={if(@ecr_configured?, do: "••••••••", else: "AWS Access Key")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Secret Key</label>
              <input
                type="password"
                name="registry[ecr_secret_key]"
                placeholder="AWS Secret Key"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Region</label>
              <input
                type="text"
                name="registry[ecr_region]"
                placeholder="us-east-1"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div class="flex gap-3">
              <.button
                type="submit"
                label="Save"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
              />
              <button
                type="button"
                class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
              >
                Test
              </button>
            </div>
          </.form>
        </div>

        <%!-- Docker Hub --%>
        <div class="rounded-lg border border-base-content/[0.06] p-4">
          <h3 class="text-sm font-semibold text-base-content mb-4">Docker Hub</h3>
          <.form
            for={%{"registry" => "docker_hub"}}
            id="registry-dockerhub-form"
            phx-submit="save_registry"
            class="space-y-4"
          >
            <input type="hidden" name="registry[registry]" value="docker_hub" />
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Token</label>
              <input
                type="password"
                name="registry[docker_hub_token]"
                placeholder={if(@docker_hub_token_set?, do: "••••••••", else: "Docker Hub token")}
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div class="flex gap-3">
              <.button
                type="submit"
                label="Save"
                class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
              />
              <button
                type="button"
                class="px-4 py-2 rounded-lg text-sm font-medium text-base-content/60 hover:bg-base-content/5 cursor-pointer"
              >
                Test
              </button>
            </div>
          </.form>
        </div>
      </div>
    </div>
    """
  end

  defp render_import(assigns) do
    ~H"""
    <div class="p-4 space-y-4">
      <div class="flex items-start justify-between gap-4">
        <div>
          <h2 class="text-lg font-semibold text-base-content">Import existing stack</h2>
          <p class="text-sm text-base-content/50">
            Discover containers under your existing <code>~/homelab</code>
            stack and migrate them into managed, plane-owned volumes. Preview only — nothing runs yet.
          </p>
        </div>
        <button
          type="button"
          phx-click="run_discovery"
          class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium hover:bg-primary/90 transition-colors cursor-pointer whitespace-nowrap"
        >
          {if(@import_services, do: "Re-scan", else: "Discover")}
        </button>
      </div>

      <div
        :if={@import_error}
        class="rounded-lg bg-error/10 border border-error/20 p-3 text-sm text-error"
      >
        {@import_error}
      </div>

      <p
        :if={is_nil(@import_services) && is_nil(@import_error)}
        class="text-sm text-base-content/40 py-6 text-center"
      >
        Click <strong>Discover</strong> to scan the running daemon for in-scope services.
      </p>

      <p :if={@import_services == []} class="text-sm text-base-content/40 py-6 text-center">
        No in-scope services found under the adoption root.
      </p>

      <div :if={@import_services not in [nil, []]} class="space-y-2">
        <div
          :for={svc <- @import_services}
          class="rounded-lg border border-base-content/[0.06] p-3"
        >
          <label class="flex items-start gap-3 cursor-pointer">
            <input
              type="checkbox"
              checked={MapSet.member?(@import_selected, svc.name)}
              phx-click="toggle_import_service"
              phx-value-name={svc.name}
              class="mt-1 rounded"
            />
            <div class="min-w-0 flex-1">
              <div class="flex items-center gap-2 flex-wrap">
                <span class="font-semibold text-sm text-base-content">{svc.name}</span>
                <span class="text-[11px] text-base-content/40 font-mono">{svc.image}</span>
                <span
                  :if={svc.user}
                  class="text-[10px] bg-base-200 rounded px-1.5 py-0.5 text-base-content/60"
                >
                  uid {svc.user}
                </span>
              </div>
              <div class="flex items-center gap-1.5 mt-1.5 flex-wrap">
                <span
                  :if={svc.preserve != []}
                  class="text-[11px] font-semibold text-success bg-success/15 rounded px-2 py-0.5"
                >
                  {length(svc.preserve)} preserve
                </span>
                <span
                  :if={svc.rebuildable != []}
                  class="text-[11px] font-semibold text-info bg-info/15 rounded px-2 py-0.5"
                >
                  {length(svc.rebuildable)} rebuildable
                </span>
                <span
                  :if={svc.out_of_scope != []}
                  class="text-[11px] font-semibold text-base-content/50 bg-base-content/10 rounded px-2 py-0.5"
                >
                  {length(svc.out_of_scope)} out of scope
                </span>
              </div>
              <ul :if={svc.preserve != []} class="mt-1.5 space-y-0.5">
                <li :for={m <- svc.preserve} class="text-[11px] text-base-content/45 font-mono">
                  {m.target} ← {m.source}
                </li>
              </ul>
            </div>
          </label>
        </div>

        <button
          type="button"
          phx-click="preview_plan"
          disabled={MapSet.size(@import_selected) == 0}
          class="px-4 py-2 rounded-lg bg-base-200 text-base-content text-sm font-medium hover:bg-base-300 transition-colors cursor-pointer disabled:opacity-50"
        >
          Preview migration plan
        </button>
      </div>

      <div :if={@import_plan} class="rounded-lg border border-base-content/[0.06] p-4 space-y-3">
        <h3 class="text-sm font-semibold text-base-content">
          Plan preview — {length(@import_plan.services)} service(s), not executed
        </h3>
        <div>
          <p class="text-xs font-semibold text-base-content/60 mb-1">
            Phase 1 — copy while the stack stays up
          </p>
          <ol class="list-decimal list-inside space-y-0.5">
            <li :for={step <- @import_plan.phase1} class="text-[11px] font-mono text-base-content/60">
              {step.type} {plan_step_detail(step)}
            </li>
          </ol>
        </div>
        <div>
          <p class="text-xs font-semibold text-warning/80 mb-1">
            Phase 2 — cutover (one outage; run only after Phase 1 is verified)
          </p>
          <ol class="list-decimal list-inside space-y-0.5">
            <li :for={step <- @import_plan.phase2} class="text-[11px] font-mono text-base-content/60">
              {step.type} {plan_step_detail(step)}
            </li>
          </ol>
        </div>
      </div>
    </div>
    """
  end

  # A short human summary of a plan step's resource_handle for the preview.
  defp plan_step_detail(%{resource_handle: %{"container" => c}}), do: "· #{c}"

  defp plan_step_detail(%{resource_handle: %{"targets" => t}}) when is_list(t),
    do: "· #{length(t)} target(s)"

  defp plan_step_detail(%{resource_handle: %{"service" => s}}), do: "· #{s}"
  defp plan_step_detail(_), do: ""

  defp render_users(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-base-content mb-4">Users</h2>
      <div :if={@users == []} class="py-8 text-center text-sm text-base-content/50">
        No users yet. Users are created when they sign in via OIDC.
      </div>
      <div :if={@users != []}>
        <table class="w-full">
          <thead>
            <tr class="border-b border-base-content/[0.06]">
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-3">
                Email
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-3">
                Name
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-3">
                Role
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-4 py-3">
                Last Login
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/[0.04]">
            <tr :for={user <- @users} class="hover:bg-base-content/[0.02]">
              <td class="px-4 py-3 text-sm text-base-content">{user.email}</td>
              <td class="px-4 py-3 text-sm text-base-content/70">{user.name || "—"}</td>
              <td class="px-4 py-3">
                <form phx-change="update_user_role" class="inline">
                  <input type="hidden" name="user_id" value={user.id} />
                  <select
                    name="role"
                    class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-1.5 px-2 cursor-pointer"
                  >
                    <option value="admin" selected={user.role == :admin}>Admin</option>
                    <option value="member" selected={user.role == :member}>Member</option>
                  </select>
                </form>
              </td>
              <td class="px-4 py-3 text-sm text-base-content/50">
                {(user.last_login_at && Calendar.strftime(user.last_login_at, "%b %d, %Y %H:%M")) ||
                  "—"}
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp enabled_catalog_ids do
    case Settings.get("enabled_catalogs") do
      nil ->
        ["os_bases"]

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, ids} when is_list(ids) -> ids
          _ -> ["os_bases"]
        end
    end
  end

  defp render_catalog(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-base-content mb-1">Catalog</h2>
      <p class="text-xs text-base-content/60 mb-4">
        Choose which catalog sources appear in the Workbench. Nothing is forced on you —
        enable only what you want. It's your server.
      </p>
      <div class="space-y-3">
        <label
          :for={catalog <- @all_catalogs}
          class="flex items-start gap-3 rounded-lg border border-base-content/[0.08] p-3 cursor-pointer"
        >
          <input
            type="checkbox"
            checked={catalog.id in @enabled_catalogs}
            phx-click="toggle_catalog"
            phx-value-id={catalog.id}
            class="mt-1"
          />
          <span class="text-xs">
            <span class="font-semibold text-base-content">{catalog.name}</span>
            <span class="block text-base-content/60">{catalog.description}</span>
          </span>
        </label>
      </div>
    </div>
    """
  end

  defp sweep_mode_label("sever_only"), do: "sever only"
  defp sweep_mode_label("armed"), do: "armed"
  defp sweep_mode_label("paused"), do: "paused"
  defp sweep_mode_label(other), do: other

  defp render_danger_zone(assigns) do
    ~H"""
    <div class="p-4">
      <h2 class="text-lg font-semibold text-error mb-4">Danger Zone</h2>
      <div class="space-y-4">
        <div class="rounded-lg border border-error/20 bg-error/5 p-4">
          <h3 class="text-sm font-semibold text-base-content mb-2">Orphan sweep</h3>
          <p class="text-xs text-base-content/60 mb-4">
            An orphan is a managed container with no deployment record. Choose what the
            reconciler does when it finds one.
          </p>
          <div class="space-y-3">
            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="radio"
                name="sweep_mode"
                value="sever_only"
                checked={@sweep_mode == "sever_only"}
                phx-click="save_sweep_mode"
                phx-value-mode="sever_only"
                class="mt-1"
              />
              <span class="text-xs">
                <span class="font-semibold text-base-content">Sever only (default)</span>
                <span class="block text-base-content/60">
                  Orphans lose their public route and are listed below, but are never deleted automatically.
                </span>
              </span>
            </label>
            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="radio"
                name="sweep_mode"
                value="armed"
                checked={@sweep_mode == "armed"}
                phx-click="save_sweep_mode"
                phx-value-mode="armed"
                data-confirm="Arm the orphan sweep? Managed containers without a deployment record will be PERMANENTLY REMOVED after the grace period."
                class="mt-1"
              />
              <span class="text-xs">
                <span class="font-semibold text-error">Armed</span>
                <span class="block text-base-content/60">
                  Orphans are deleted after the grace period. Use only when you trust every managed label.
                </span>
              </span>
            </label>
            <label class="flex items-start gap-3 cursor-pointer">
              <input
                type="radio"
                name="sweep_mode"
                value="paused"
                checked={@sweep_mode == "paused"}
                phx-click="save_sweep_mode"
                phx-value-mode="paused"
                class="mt-1"
              />
              <span class="text-xs">
                <span class="font-semibold text-base-content">Paused</span>
                <span class="block text-base-content/60">
                  No orphan handling at all — severed routes are not re-enforced. For manual surgery.
                </span>
              </span>
            </label>
          </div>

          <div :if={@orphans != []} class="mt-4">
            <h4 class="text-xs font-semibold text-base-content mb-2">Orphaned containers</h4>
            <table class="w-full text-xs">
              <thead>
                <tr class="text-left text-base-content/50">
                  <th class="py-1 pr-2">Name</th>
                  <th class="py-1 pr-2">Container</th>
                  <th class="py-1 pr-2">Tenant / App</th>
                  <th class="py-1 pr-2">Detected</th>
                  <th class="py-1"></th>
                </tr>
              </thead>
              <tbody>
                <tr :for={orphan <- @orphans} class="border-t border-base-content/[0.06]">
                  <td class="py-1 pr-2 font-mono">{orphan.name}</td>
                  <td class="py-1 pr-2 font-mono text-base-content/50">
                    {String.slice(orphan.id, 0, 12)}
                  </td>
                  <td class="py-1 pr-2">{orphan.tenant || "—"} / {orphan.app || "—"}</td>
                  <td class="py-1 pr-2 text-base-content/50">
                    {Calendar.strftime(orphan.detected_at, "%Y-%m-%d %H:%M")}
                  </td>
                  <td class="py-1 text-right">
                    <button
                      type="button"
                      phx-click="remove_orphan"
                      phx-value-id={orphan.id}
                      data-confirm={"Permanently remove container #{orphan.name}? This cannot be undone."}
                      class="text-error hover:underline cursor-pointer"
                    >
                      Remove now
                    </button>
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
        <div class="rounded-lg border border-error/20 bg-error/5 p-4">
          <h3 class="text-sm font-semibold text-base-content mb-2">Re-run Setup Wizard</h3>
          <p class="text-xs text-base-content/60 mb-4">
            Clear setup completion and return to the setup wizard. You will need to reconfigure instance settings.
          </p>
          <button
            type="button"
            phx-click="rerun_setup"
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium text-error hover:bg-error/10 transition-colors cursor-pointer"
          >
            <.icon name="hero-arrow-right" class="size-4" /> Go to Setup
          </button>
        </div>
        <div class="rounded-lg border border-base-content/[0.08] p-4">
          <h3 class="text-sm font-semibold text-base-content mb-2">Export Config</h3>
          <p class="text-xs text-base-content/60 mb-4">
            Download this instance's non-secret settings as JSON. Encrypted secrets are excluded.
          </p>
          <a
            href={~p"/settings/export"}
            download
            class="inline-flex items-center gap-2 px-4 py-2 rounded-lg text-sm font-medium text-base-content/70 hover:bg-base-content/5 cursor-pointer"
          >
            <.icon name="hero-arrow-down-tray" class="size-4" /> Export
          </a>
        </div>
      </div>
    </div>
    """
  end
end
