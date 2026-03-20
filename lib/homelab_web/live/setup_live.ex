defmodule HomelabWeb.SetupLive do
  @moduledoc """
  Multi-step first-run setup wizard for Homelab.
  """
  use HomelabWeb, :live_view

  alias Homelab.Settings
  alias Homelab.Auth.OidcDiscovery
  alias Homelab.Docker.Client, as: DockerClient
  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant

  @impl true
  def mount(params, _session, socket) do
    if connected?(socket) do
      Settings.subscribe()
    end

    step = parse_step(params)

    socket =
      socket
      |> assign(:step, step)
      |> assign(:page_title, "Setup")
      |> assign(:instance_name, Settings.get("instance_name", ""))
      |> assign(:base_domain, Settings.get("base_domain", ""))
      |> assign(:step1_form, step1_form(step1_params()))
      |> assign(:oidc_form, step2_form(step2_params()))
      |> assign(:oidc_discovery, nil)
      |> assign(:oidc_test_result, nil)
      |> assign(:docker_info, nil)
      |> assign(:selected_orchestrator, Settings.get("orchestrator", "docker_engine"))
      |> assign(:selected_gateway, Settings.get("gateway"))
      |> assign(:swarm_available?, false)
      |> assign(:space_form, to_form(Tenants.change_tenant(%Tenant{})))
      |> maybe_check_docker()
      |> assign(:created_space, nil)

    {:ok, socket}
  end

  @impl true
  def handle_info({:setting_changed, _key}, socket) do
    {:noreply, socket}
  end

  def handle_info(:check_docker, socket) do
    {:noreply, maybe_check_docker(socket)}
  end

  defp step1_params do
    %{
      "instance_name" => Settings.get("instance_name", ""),
      "base_domain" => Settings.get("base_domain", "")
    }
  end

  defp step2_params do
    %{
      "oidc_issuer" => Settings.get("oidc_issuer", ""),
      "oidc_client_id" => Settings.get("oidc_client_id", ""),
      "oidc_client_secret" => ""
    }
  end

  defp step1_form(params), do: to_form(params, as: :step1)
  defp step2_form(params), do: to_form(params, as: :oidc)

  defp maybe_check_docker(socket) do
    if socket.assigns.step == 3 and connected?(socket) do
      case DockerClient.get("/info") do
        {:ok, info} ->
          swarm_active? = get_in(info, ["Swarm", "LocalNodeState"]) == "active"

          socket
          |> assign(:docker_info, {:ok, info})
          |> assign(:swarm_available?, swarm_active?)

        {:error, reason} ->
          assign(socket, :docker_info, {:error, reason})
      end
    else
      socket
    end
  end

  @impl true
  def handle_params(params, _uri, socket) do
    step = parse_step(params)
    socket = assign(socket, :step, step)

    socket =
      cond do
        step == 3 ->
          maybe_check_docker(socket)

        step == 5 ->
          mark_setup_completed(socket)

        true ->
          socket
      end

    {:noreply, socket}
  end

  defp parse_step(params) do
    case params["step"] do
      nil ->
        1

      s when is_binary(s) ->
        case Integer.parse(s) do
          {n, _} when n in 1..5 -> n
          _ -> 1
        end
    end
  end

  defp mark_setup_completed(socket) do
    Settings.mark_setup_completed()
    socket
  end

  @impl true
  # Step 1: Welcome
  def handle_event(
        "save_step_1",
        %{"step1" => %{"instance_name" => name, "base_domain" => domain}},
        socket
      ) do
    Settings.set("instance_name", name)
    Settings.set("base_domain", domain)

    {:noreply,
     socket
     |> assign(:instance_name, name)
     |> assign(:base_domain, domain)
     |> push_patch(to: ~p"/setup?step=2")}
  end

  def handle_event("validate_step_1", %{"step1" => params}, socket) do
    form = step1_form(params)
    {:noreply, assign(socket, :step1_form, form)}
  end

  # Step 2: Authentication
  def handle_event("discover_oidc", _params, socket) do
    url = get_oidc_issuer_from_form(socket)

    result =
      if url != "" do
        OidcDiscovery.discover(url)
      else
        nil
      end

    {:noreply,
     socket
     |> assign(:oidc_discovery, result)
     |> assign(:oidc_test_result, nil)}
  end

  def handle_event("test_oidc", _params, socket) do
    url = get_oidc_issuer_from_form(socket)

    result =
      if url != "" do
        case Req.get(String.trim_trailing(url, "/"), retry: false, receive_timeout: 5_000) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            {:ok, "Connection successful"}

          {:ok, %Req.Response{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, inspect(reason)}
        end
      else
        {:error, "Enter an OIDC Issuer URL first"}
      end

    {:noreply, assign(socket, :oidc_test_result, result)}
  end

  def handle_event("validate_oidc", %{"oidc" => params}, socket) do
    form = step2_form(params)
    {:noreply, assign(socket, :oidc_form, form)}
  end

  def handle_event("save_step_2", %{"oidc" => oidc_params}, socket) do
    issuer = oidc_params["oidc_issuer"] || ""
    client_id = oidc_params["oidc_client_id"] || ""
    secret = oidc_params["oidc_client_secret"] || ""

    if issuer == "" or client_id == "" do
      {:noreply, put_flash(socket, :error, "Issuer URL and Client ID are required.")}
    else
      Settings.set("oidc_issuer", issuer)
      Settings.set("oidc_client_id", client_id)

      if secret != "" do
        Settings.set("oidc_client_secret", secret, encrypt: true)
      end

      {:noreply, push_patch(socket, to: ~p"/setup?step=3")}
    end
  end

  def handle_event("validate_space", %{"tenant" => params}, socket) do
    params = maybe_auto_generate_slug(params)
    form = to_form(Tenants.change_tenant(%Tenant{}, params), as: :tenant)
    {:noreply, assign(socket, :space_form, form)}
  end

  def handle_event("generate_slug", _params, socket) do
    params = socket.assigns.space_form.params || %{}
    name = params["name"] || ""
    slug = params["slug"] || ""

    new_slug =
      if name != "" and slug == "" do
        slugify(name)
      else
        slug
      end

    params = Map.put(params, "slug", new_slug)
    form = to_form(Tenants.change_tenant(%Tenant{}, params), as: :tenant)
    {:noreply, assign(socket, :space_form, form)}
  end

  def handle_event("create_space", %{"tenant" => params}, socket) do
    params = maybe_auto_generate_slug(params)

    case Tenants.create_tenant(params) do
      {:ok, tenant} ->
        {:noreply,
         socket
         |> assign(:created_space, tenant)
         |> assign(:space_form, to_form(Tenants.change_tenant(%Tenant{})))
         |> push_patch(to: ~p"/setup?step=5")}

      {:error, changeset} ->
        {:noreply, assign(socket, :space_form, to_form(changeset))}
    end
  end

  def handle_event("select_orchestrator", %{"driver" => driver_id}, socket) do
    {:noreply, assign(socket, :selected_orchestrator, driver_id)}
  end

  def handle_event("select_gateway", %{"driver" => driver_id}, socket) do
    {:noreply, assign(socket, :selected_gateway, driver_id)}
  end

  def handle_event("save_step_3", _params, socket) do
    driver_id = socket.assigns.selected_orchestrator

    if driver_id do
      Homelab.Settings.set("orchestrator", driver_id)

      if gw = socket.assigns.selected_gateway do
        Homelab.Settings.set("gateway", gw)
      end

      step = min(socket.assigns.step + 1, 5)
      {:noreply, push_patch(socket, to: ~p"/setup?step=#{step}")}
    else
      {:noreply, put_flash(socket, :error, "Please select an orchestrator.")}
    end
  end

  def handle_event("next", _params, socket) do
    step = min(socket.assigns.step + 1, 5)
    {:noreply, push_patch(socket, to: ~p"/setup?step=#{step}")}
  end

  def handle_event("back", _params, socket) do
    step = max(socket.assigns.step - 1, 1)
    {:noreply, push_patch(socket, to: ~p"/setup?step=#{step}")}
  end

  defp get_oidc_issuer_from_form(socket) do
    form = socket.assigns.oidc_form
    form.params["oidc_issuer"] || ""
  end

  defp maybe_auto_generate_slug(params) do
    name = params["name"] || ""
    slug = params["slug"] || ""

    new_slug =
      if name != "" and slug == "" do
        slugify(name)
      else
        slug
      end

    Map.put(params, "slug", new_slug)
  end

  defp slugify(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9\s-]/, "")
    |> String.replace(~r/[\s]+/, "-")
    |> String.replace(~r/-+/, "-")
    |> String.trim("-")
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.setup flash={@flash} page_title={@page_title}>
      <div class="flex flex-col items-center min-h-[80vh] py-12">
        <div class="w-full max-w-xl">
          <%!-- Step indicator --%>
          <div class="flex items-center justify-center gap-2 mb-10">
            <div :for={n <- 1..5} class="flex items-center">
              <div class={[
                "w-9 h-9 rounded-full flex items-center justify-center text-sm font-semibold transition-colors",
                @step == n && "bg-primary text-primary-content",
                @step > n && "bg-primary/20 text-primary",
                @step < n && "bg-base-300 text-base-content/40"
              ]}>
                {n}
              </div>
              <div
                :if={n < 5}
                class={["w-8 h-0.5 mx-0.5", @step > n && "bg-primary/30", @step <= n && "bg-base-300"]}
              >
              </div>
            </div>
          </div>

          <%!-- Gradient header --%>
          <div class="relative overflow-hidden rounded-lg bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-6 mb-5">
            <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl">
            </div>
            <div class="absolute -bottom-16 -left-16 w-48 h-48 bg-accent/5 rounded-full blur-3xl">
            </div>
            <div class="relative">
              <div class="flex items-center gap-3 mb-2">
                <div class="w-10 h-10 rounded-lg bg-primary/20 flex items-center justify-center">
                  <.icon name="hero-cog-6-tooth-solid" class="size-5 text-primary" />
                </div>
                <h1 class="text-2xl font-bold text-base-content tracking-tight">Setup Wizard</h1>
              </div>
              <p class="text-sm text-base-content/50 leading-relaxed">
                {step_subtitle(@step)}
              </p>
            </div>
          </div>

          <%!-- Step content --%>
          <div class="rounded-lg border border-base-content/[0.06] bg-base-100 p-8">
            {step_content(assigns)}
          </div>
        </div>
      </div>
    </Layouts.setup>
    """
  end

  defp step_subtitle(1), do: "Configure your Homelab instance"
  defp step_subtitle(2), do: "Connect your authentication provider"
  defp step_subtitle(3), do: "Verify infrastructure connectivity"
  defp step_subtitle(4), do: "Create your first space"
  defp step_subtitle(5), do: "You're all set!"
  defp step_subtitle(_), do: ""

  defp step_content(assigns) do
    case assigns.step do
      1 -> render_step1(assigns)
      2 -> render_step2(assigns)
      3 -> render_step3(assigns)
      4 -> render_step4(assigns)
      5 -> render_step5(assigns)
      _ -> render_step1(assigns)
    end
  end

  defp render_step1(assigns) do
    ~H"""
    <.form
      for={@step1_form}
      id="step1-form"
      phx-change="validate_step_1"
      phx-submit="save_step_1"
      class="space-y-4"
    >
      <div>
        <.input
          field={@step1_form["instance_name"]}
          type="text"
          label="Instance Name"
          placeholder="My Homelab"
        />
      </div>
      <div>
        <.input
          field={@step1_form["base_domain"]}
          type="text"
          label="Base Domain"
          placeholder="lab.example.com"
        />
      </div>
      <div class="flex justify-end pt-4">
        <button
          type="submit"
          class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
        >
          Next
        </button>
      </div>
    </.form>
    """
  end

  defp render_step2(assigns) do
    callback_url = build_callback_url(assigns.base_domain)

    assigns = assign(assigns, :callback_url, callback_url)

    ~H"""
    <%!-- Provider configuration reference --%>
    <div class="rounded-lg border border-info/20 bg-info/5 p-4 mb-4 space-y-3">
      <div class="flex items-center gap-2 text-info font-medium text-sm">
        <.icon name="hero-information-circle" class="size-5" />
        <span>OIDC provider configuration</span>
      </div>
      <p class="text-xs text-base-content/60 leading-relaxed">
        When creating a new client/application in your OIDC provider (Authentik, Keycloak, etc.), use the values below.
      </p>
      <div class="space-y-2.5">
        <.copiable_field label="Redirect / Callback URL" value={@callback_url} />
        <.copiable_field label="Sign-out / Post-logout URL" value={build_logout_url(@base_domain)} />
        <div>
          <p class="text-[11px] font-semibold text-base-content/50 uppercase tracking-wider mb-1">
            Required Scopes
          </p>
          <div class="flex flex-wrap gap-1.5">
            <span class="px-2 py-0.5 rounded-md bg-base-200 text-xs font-mono text-base-content/70">
              openid
            </span>
            <span class="px-2 py-0.5 rounded-md bg-base-200 text-xs font-mono text-base-content/70">
              email
            </span>
            <span class="px-2 py-0.5 rounded-md bg-base-200 text-xs font-mono text-base-content/70">
              profile
            </span>
          </div>
        </div>
        <div>
          <p class="text-[11px] font-semibold text-base-content/50 uppercase tracking-wider mb-1">
            Grant Type
          </p>
          <span class="px-2 py-0.5 rounded-md bg-base-200 text-xs font-mono text-base-content/70">
            Authorization Code
          </span>
        </div>
        <div>
          <p class="text-[11px] font-semibold text-base-content/50 uppercase tracking-wider mb-1">
            Client Type
          </p>
          <span class="text-xs text-base-content/60">
            Confidential (with a client secret)
          </span>
        </div>
      </div>
    </div>

    <.form
      for={@oidc_form}
      id="step2-form"
      phx-change="validate_oidc"
      phx-submit="save_step_2"
      class="space-y-4"
    >
      <div>
        <.input
          field={@oidc_form["oidc_issuer"]}
          type="url"
          label="OIDC Issuer URL"
          placeholder="https://accounts.google.com"
          phx-blur="discover_oidc"
        />
      </div>

      <%!-- OIDC Discovery result --%>
      <div :if={@oidc_discovery != nil}>
        <%= case @oidc_discovery do %>
          <% {:ok, discovery} -> %>
            <div class="rounded-lg border border-success/20 bg-success/5 p-4 space-y-3">
              <div class="flex items-center gap-2 text-success font-medium">
                <.icon name="hero-check-circle" class="size-5" />
                <span>OIDC discovery successful</span>
              </div>
              <div class="grid grid-cols-1 gap-2 text-sm">
                <div class="flex items-center gap-2">
                  <%= if OidcDiscovery.supports_authorization_code?(discovery) do %>
                    <.icon name="hero-check-circle" class="size-4 text-success" />
                  <% else %>
                    <.icon name="hero-x-mark" class="size-4 text-error" />
                  <% end %>
                  <span>Authorization Code</span>
                </div>
                <div class="flex items-center gap-2">
                  <%= if OidcDiscovery.supports_device_flow?(discovery) do %>
                    <.icon name="hero-check-circle" class="size-4 text-success" />
                  <% else %>
                    <.icon name="hero-x-mark" class="size-4 text-error" />
                  <% end %>
                  <span>Device Code</span>
                </div>
                <div class="flex items-center gap-2">
                  <%= if OidcDiscovery.supports_refresh?(discovery) do %>
                    <.icon name="hero-check-circle" class="size-4 text-success" />
                  <% else %>
                    <.icon name="hero-x-mark" class="size-4 text-error" />
                  <% end %>
                  <span>Refresh Token</span>
                </div>
              </div>
            </div>
            <div class="space-y-4">
              <div>
                <.input
                  field={@oidc_form["oidc_client_id"]}
                  type="text"
                  label="Client ID"
                />
              </div>
              <div>
                <.input
                  field={@oidc_form["oidc_client_secret"]}
                  type="password"
                  label="Client Secret"
                />
              </div>
            </div>
          <% {:error, _} -> %>
            <div class="rounded-lg border border-error/20 bg-error/5 p-4 flex items-center gap-2 text-error">
              <.icon name="hero-x-mark" class="size-5 shrink-0" />
              <span>Failed to discover OIDC configuration. Check the issuer URL.</span>
            </div>
          <% nil -> %>
            <div class="rounded-lg border border-base-content/10 bg-base-200/50 p-4 text-sm text-base-content/50">
              Enter an OIDC Issuer URL and blur the field to discover capabilities.
            </div>
        <% end %>
      </div>

      <div :if={@oidc_discovery == nil} class="text-sm text-base-content/40">
        Enter your OIDC provider URL (e.g. Keycloak, Authentik, Google) and tab out to discover.
      </div>

      <div :if={@oidc_test_result != nil} class="rounded-lg p-4 border border-base-content/10">
        <%= case @oidc_test_result do %>
          <% {:ok, msg} -> %>
            <div class="flex items-center gap-2 text-success">
              <.icon name="hero-check-circle" class="size-5" />
              <span>{msg}</span>
            </div>
          <% {:error, msg} -> %>
            <div class="flex items-center gap-2 text-error">
              <.icon name="hero-x-mark" class="size-5" />
              <span>{msg}</span>
            </div>
        <% end %>
      </div>

      <div class="flex justify-between pt-4">
        <button
          type="button"
          phx-click="back"
          class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
        >
          Back
        </button>
        <div class="flex gap-3">
          <button
            type="button"
            phx-click="test_oidc"
            class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
          >
            Test Connection
          </button>
          <button
            type="submit"
            class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
          >
            Next
          </button>
        </div>
      </div>
    </.form>
    """
  end

  defp render_step3(assigns) do
    orchestrators = Homelab.Config.orchestrators()
    gateways = Homelab.Config.gateways()

    assigns =
      assigns
      |> assign(:orchestrators, orchestrators)
      |> assign(:gateways, gateways)

    ~H"""
    <div class="space-y-4">
      <div :if={@docker_info != nil}>
        <%= case @docker_info do %>
          <% {:ok, info} -> %>
            <div class="rounded-lg border border-success/20 bg-success/5 p-4 space-y-4">
              <div class="flex items-center gap-2 text-success font-medium">
                <.icon name="hero-check-circle" class="size-5" />
                <span>Docker connected</span>
              </div>
              <div class="grid grid-cols-2 gap-4 text-sm">
                <div>
                  <p class="text-base-content/50 text-xs uppercase tracking-wider">Version</p>
                  <p class="font-mono font-medium">{info["ServerVersion"] || "—"}</p>
                </div>
                <div>
                  <p class="text-base-content/50 text-xs uppercase tracking-wider">Containers</p>
                  <p class="font-medium">{info["Containers"] || 0}</p>
                </div>
                <div>
                  <p class="text-base-content/50 text-xs uppercase tracking-wider">Images</p>
                  <p class="font-medium">{info["Images"] || 0}</p>
                </div>
                <div>
                  <p class="text-base-content/50 text-xs uppercase tracking-wider">Swarm</p>
                  <p class="font-medium">
                    <%= if @swarm_available? do %>
                      <span class="text-success">Active</span>
                    <% else %>
                      <span class="text-base-content/40">Inactive</span>
                    <% end %>
                  </p>
                </div>
              </div>
            </div>
          <% {:error, reason} -> %>
            <div class="rounded-lg border border-error/20 bg-error/5 p-4">
              <div class="flex items-center gap-2 text-error font-medium mb-2">
                <.icon name="hero-x-mark" class="size-5" />
                <span>Docker not connected</span>
              </div>
              <p class="text-sm text-base-content/70">{format_docker_error(reason)}</p>
            </div>
        <% end %>
      </div>

      <div :if={@docker_info == nil} class="flex items-center gap-3 text-base-content/50">
        <.icon name="hero-arrow-path" class="size-5 animate-spin" />
        <span>Checking Docker connection...</span>
      </div>

      <%!-- Orchestrator selection --%>
      <div>
        <p class="text-sm font-semibold text-base-content mb-3">Container Orchestrator</p>
        <div class="space-y-2">
          <button
            :for={mod <- @orchestrators}
            type="button"
            phx-click="select_orchestrator"
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

      <%!-- Gateway / Reverse Proxy selection --%>
      <div>
        <p class="text-sm font-semibold text-base-content mb-1">Reverse Proxy</p>
        <p class="text-xs text-base-content/50 mb-3">
          Routes traffic to your apps via their domains on ports 80/443.
        </p>
        <div class="space-y-2">
          <button
            :for={mod <- @gateways}
            type="button"
            phx-click="select_gateway"
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

      <div class="flex justify-between pt-4">
        <button
          type="button"
          phx-click="back"
          class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
        >
          Back
        </button>
        <button
          type="button"
          phx-click="save_step_3"
          class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
        >
          Next
        </button>
      </div>
    </div>
    """
  end

  defp format_docker_error({:connection_error, reason}),
    do: "Connection failed: #{inspect(reason)}"

  defp format_docker_error({:http_error, status, _}), do: "HTTP error: #{status}"
  defp format_docker_error(other), do: inspect(other)

  defp render_step4(assigns) do
    ~H"""
    <.form
      for={@space_form}
      id="step4-form"
      phx-change="validate_space"
      phx-submit="create_space"
      class="space-y-4"
    >
      <div>
        <.input
          field={@space_form[:name]}
          type="text"
          label="Space Name"
          placeholder="My Production Apps"
          phx-blur="generate_slug"
        />
      </div>
      <div>
        <.input
          field={@space_form[:slug]}
          type="text"
          label="Slug"
          placeholder="my-production-apps"
        />
        <p class="text-[11px] text-base-content/30 mt-1.5">
          Lowercase letters, numbers, and hyphens only.
        </p>
      </div>

      <div class="flex justify-between pt-4">
        <button
          type="button"
          phx-click="back"
          class="px-4 py-2.5 rounded-lg text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
        >
          Back
        </button>
        <button
          type="submit"
          class="px-5 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
        >
          Create Space
        </button>
      </div>
    </.form>
    """
  end

  attr :label, :string, required: true
  attr :value, :string, required: true

  defp copiable_field(assigns) do
    id = "copy-#{:erlang.phash2(assigns.value)}"
    assigns = assign(assigns, :id, id)

    ~H"""
    <div>
      <p class="text-[11px] font-semibold text-base-content/50 uppercase tracking-wider mb-1">
        {@label}
      </p>
      <div class="flex items-center gap-2">
        <code class="flex-1 px-3 py-1.5 rounded-lg bg-base-200 text-xs font-mono text-base-content/80 select-all break-all">
          {@value}
        </code>
        <button
          type="button"
          id={@id}
          phx-hook=".CopyButton"
          data-copy-text={@value}
          class="shrink-0 p-1.5 rounded-lg hover:bg-base-200 text-base-content/40 hover:text-base-content/70 transition-colors cursor-pointer"
          title="Copy to clipboard"
        >
          <.icon name="hero-clipboard-document" class="size-4" />
        </button>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".CopyButton">
      export default {
        mounted() {
          this.el.addEventListener("click", () => {
            const text = this.el.dataset.copyText
            navigator.clipboard.writeText(text).then(() => {
              const original = this.el.innerHTML
              this.el.innerHTML = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 20 20" fill="currentColor" class="size-4 text-success"><path fill-rule="evenodd" d="M16.704 4.153a.75.75 0 0 1 .143 1.052l-8 10.5a.75.75 0 0 1-1.127.075l-4.5-4.5a.75.75 0 0 1 1.06-1.06l3.894 3.893 7.48-9.817a.75.75 0 0 1 1.05-.143Z" clip-rule="evenodd" /></svg>`
              setTimeout(() => { this.el.innerHTML = original }, 1500)
            })
          })
        }
      }
    </script>
    """
  end

  defp build_callback_url(base_domain) do
    host = if base_domain != "" and base_domain != nil, do: base_domain, else: "localhost:4000"
    scheme = if host =~ "localhost", do: "http", else: "https"
    "#{scheme}://#{host}/auth/oidc/callback"
  end

  defp build_logout_url(base_domain) do
    host = if base_domain != "" and base_domain != nil, do: base_domain, else: "localhost:4000"
    scheme = if host =~ "localhost", do: "http", else: "https"
    "#{scheme}://#{host}"
  end

  defp render_step5(assigns) do
    ~H"""
    <div class="space-y-4 text-center">
      <div class="flex justify-center">
        <div class="w-16 h-16 rounded-lg bg-success/20 flex items-center justify-center">
          <.icon name="hero-check-circle" class="size-8 text-success" />
        </div>
      </div>
      <div>
        <h2 class="text-xl font-bold text-base-content mb-2">Setup complete!</h2>
        <p class="text-base-content/60 text-sm">
          Your Homelab is ready. Here's what was configured:
        </p>
      </div>
      <div class="rounded-lg border border-base-content/10 bg-base-200/50 p-4 text-left text-sm space-y-2">
        <p><span class="font-medium text-base-content/60">Instance:</span> {@instance_name}</p>
        <p><span class="font-medium text-base-content/60">Domain:</span> {@base_domain}</p>
        <p :if={@created_space}>
          <span class="font-medium text-base-content/60">First space:</span> {@created_space.name}
        </p>
      </div>
      <div class="pt-4">
        <.link
          navigate={~p"/"}
          class="inline-flex items-center gap-2 px-4 py-2.5 rounded-lg bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all"
        >
          <.icon name="hero-arrow-right" class="size-5" /> Go to Dashboard
        </.link>
      </div>
    </div>
    """
  end
end
