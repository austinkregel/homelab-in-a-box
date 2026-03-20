defmodule HomelabWeb.DomainsLive do
  use HomelabWeb, :live_view

  alias Homelab.Tenants
  alias Homelab.Networking
  alias Homelab.Deployments

  @tabs ~w(zones domains records)

  @impl true
  def mount(_params, _session, socket) do
    tenants = Tenants.list_active_tenants()

    socket =
      socket
      |> assign(:page_title, "Domains & DNS")
      |> assign(:tenants, tenants)
      |> assign(:active_tab, "zones")
      |> assign(:show_modal, nil)
      |> assign(:modal_form, nil)
      |> assign(:syncing, false)
      |> load_all_data()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    tab = params["tab"]
    tab = if tab in @tabs, do: tab, else: "zones"
    {:noreply, assign(socket, :active_tab, tab)}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => tab}, socket) when tab in @tabs do
    {:noreply,
     socket
     |> assign(:active_tab, tab)
     |> push_patch(to: ~p"/domains?tab=#{tab}")}
  end

  def handle_event("sync_registrar", _params, socket) do
    socket = assign(socket, :syncing, true)
    send(self(), :do_sync_registrar)
    {:noreply, socket}
  end

  def handle_event("open_add_zone", _params, socket) do
    form = to_form(%{"name" => "", "provider" => "manual"}, as: :zone)
    {:noreply, assign(socket, show_modal: :add_zone, modal_form: form)}
  end

  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, show_modal: nil, modal_form: nil)}
  end

  def handle_event("save_zone", %{"zone" => params}, socket) do
    case Networking.create_dns_zone(params) do
      {:ok, _zone} ->
        {:noreply,
         socket
         |> load_all_data()
         |> assign(show_modal: nil, modal_form: nil)
         |> put_flash(:info, "Zone created successfully!")}

      {:error, changeset} ->
        {:noreply, assign(socket, modal_form: to_form(changeset, as: :zone))}
    end
  end

  def handle_event("delete_zone", %{"id" => id}, socket) do
    zone = Networking.get_dns_zone!(String.to_integer(id))

    case Networking.delete_dns_zone(zone) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_all_data()
         |> put_flash(:info, "Zone deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete zone.")}
    end
  end

  def handle_event("open_add_domain", _params, socket) do
    form =
      to_form(%{"deployment_id" => "", "domain" => "", "dns_zone_id" => ""},
        as: :add_domain
      )

    {:noreply, assign(socket, show_modal: :add_domain, modal_form: form)}
  end

  def handle_event(
        "save_domain",
        %{"add_domain" => %{"deployment_id" => deployment_id, "domain" => domain} = params},
        socket
      ) do
    deployment_id = String.to_integer(deployment_id)

    case Deployments.get_deployment(deployment_id) do
      {:ok, deployment} ->
        case Deployments.update_deployment(deployment, %{domain: domain}) do
          {:ok, _} ->
            dns_zone_id = params["dns_zone_id"]

            if dns_zone_id && dns_zone_id != "" do
              Networking.create_domain(%{
                fqdn: domain,
                deployment_id: deployment_id,
                dns_zone_id: String.to_integer(dns_zone_id),
                tls_status: :pending
              })
            end

            {:noreply,
             socket
             |> load_all_data()
             |> assign(show_modal: nil, modal_form: nil)
             |> put_flash(:info, "Domain assigned successfully!")}

          {:error, _changeset} ->
            {:noreply, put_flash(socket, :error, "Failed to assign domain.")}
        end

      {:error, :not_found} ->
        {:noreply, put_flash(socket, :error, "Deployment not found")}
    end
  end

  def handle_event("open_add_record", _params, socket) do
    form =
      to_form(
        %{
          "dns_zone_id" => "",
          "name" => "",
          "type" => "A",
          "value" => "",
          "ttl" => "300",
          "scope" => "public"
        },
        as: :record
      )

    {:noreply, assign(socket, show_modal: :add_record, modal_form: form)}
  end

  def handle_event("save_record", %{"record" => params}, socket) do
    attrs = %{
      dns_zone_id: String.to_integer(params["dns_zone_id"]),
      name: params["name"],
      type: params["type"],
      value: params["value"],
      ttl: String.to_integer(params["ttl"] || "300"),
      scope: params["scope"],
      managed: false
    }

    case Networking.create_dns_record(attrs) do
      {:ok, record} ->
        Networking.push_record_to_provider(record)

        {:noreply,
         socket
         |> load_all_data()
         |> assign(show_modal: nil, modal_form: nil)
         |> put_flash(:info, "DNS record created!")}

      {:error, changeset} ->
        {:noreply, assign(socket, modal_form: to_form(changeset, as: :record))}
    end
  end

  def handle_event("delete_record", %{"id" => id}, socket) do
    record = Networking.get_dns_record!(String.to_integer(id))

    case Networking.delete_dns_record(record) do
      {:ok, _} ->
        {:noreply,
         socket
         |> load_all_data()
         |> put_flash(:info, "DNS record deleted.")}

      {:error, _} ->
        {:noreply, put_flash(socket, :error, "Failed to delete record.")}
    end
  end

  @impl true
  def handle_info(:do_sync_registrar, socket) do
    result = Networking.sync_zones_from_registrar()

    socket =
      case result do
        {:ok, _} ->
          socket
          |> load_all_data()
          |> put_flash(:info, "Registrar sync complete!")

        {:error, :no_registrar_configured} ->
          put_flash(socket, :error, "No registrar configured. Set it up in Settings → DNS.")

        {:error, reason} ->
          put_flash(socket, :error, "Sync failed: #{inspect(reason)}")
      end

    {:noreply, assign(socket, :syncing, false)}
  end

  defp load_all_data(socket) do
    zones = Networking.list_dns_zones()
    domains = load_domains()
    deployments_without_domain = load_deployments_without_domain()

    all_records =
      Enum.flat_map(zones, fn zone ->
        Networking.list_dns_records_for_zone(zone.id)
        |> Enum.map(&Map.put(&1, :zone_name, zone.name))
      end)

    socket
    |> assign(:zones, zones)
    |> assign(:domains, domains)
    |> assign(:dns_records, all_records)
    |> assign(:deployments_without_domain, deployments_without_domain)
  end

  defp load_domains do
    networking_domains = Networking.list_domains()

    from_networking =
      Enum.map(networking_domains, fn d ->
        %{
          domain: d.fqdn,
          deployment: d.deployment,
          app_name: d.deployment.app_template.name,
          tenant_name: d.deployment.tenant.name,
          tls_status: d.tls_status,
          exposure_mode: d.exposure_mode,
          zone_name: if(d.dns_zone, do: d.dns_zone.name, else: nil)
        }
      end)

    from_deployments =
      Deployments.list_deployments()
      |> Enum.filter(fn d -> d.domain && d.domain != "" end)
      |> Enum.reject(fn d ->
        Enum.any?(networking_domains, fn nd -> nd.deployment_id == d.id end)
      end)
      |> Enum.map(fn d ->
        %{
          domain: d.domain,
          deployment: d,
          app_name: d.app_template.name,
          tenant_name: d.tenant.name,
          tls_status: :pending,
          exposure_mode: d.app_template.exposure_mode,
          zone_name: nil
        }
      end)

    from_networking ++ from_deployments
  end

  defp load_deployments_without_domain do
    Deployments.list_deployments()
    |> Enum.filter(fn d -> !d.domain || d.domain == "" end)
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
      <div class="space-y-8">
        <%!-- Page header --%>
        <div class="relative overflow-hidden rounded-2xl bg-gradient-to-br from-primary/15 via-primary/5 to-transparent border border-primary/10 px-8 py-8">
          <div class="absolute -top-20 -right-20 w-64 h-64 bg-primary/5 rounded-full blur-3xl"></div>
          <div class="relative flex items-start justify-between">
            <div>
              <div class="flex items-center gap-3 mb-2">
                <div class="w-10 h-10 rounded-xl bg-primary/20 flex items-center justify-center">
                  <.icon name="hero-globe-alt-solid" class="size-5 text-primary" />
                </div>
                <h1 class="text-2xl font-bold text-base-content tracking-tight">
                  Domains & DNS
                </h1>
              </div>
              <p class="text-sm text-base-content/50 max-w-lg leading-relaxed mt-1">
                Manage DNS zones, domain assignments, and DNS records across public and internal providers.
              </p>
            </div>
          </div>
        </div>

        <%!-- Tab navigation --%>
        <div class="flex items-center gap-1 rounded-xl bg-base-200/60 p-1 w-fit">
          <button
            :for={tab <- ~w(zones domains records)}
            type="button"
            phx-click="switch_tab"
            phx-value-tab={tab}
            class={[
              "px-4 py-2 rounded-lg text-sm font-medium transition-all duration-200 cursor-pointer",
              if(@active_tab == tab,
                do: "bg-base-100 text-base-content shadow-sm",
                else: "text-base-content/50 hover:text-base-content/70"
              )
            ]}
          >
            {tab_label(tab)}
          </button>
        </div>

        <%!-- Tab content --%>
        <div>
          <%= case @active_tab do %>
            <% "zones" -> %>
              <.zones_tab
                zones={@zones}
                syncing={@syncing}
              />
            <% "domains" -> %>
              <.domains_tab domains={@domains} />
            <% "records" -> %>
              <.records_tab dns_records={@dns_records} />
          <% end %>
        </div>

        <%!-- Modals --%>
        <.modal
          :if={@show_modal == :add_zone}
          title="Add DNS Zone"
          subtitle="Create a new DNS zone for domain management"
          icon="hero-server-stack"
          on_close="close_modal"
        >
          <.form for={@modal_form} id="add-zone-form" phx-submit="save_zone" class="space-y-4">
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Zone Name
              </label>
              <.input
                field={@modal_form[:name]}
                type="text"
                placeholder="example.com"
                required
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Provider
              </label>
              <select
                name="zone[provider]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="manual">Manual</option>
                <option value="cloudflare">Cloudflare</option>
              </select>
            </div>
            <.modal_actions />
          </.form>
        </.modal>

        <.modal
          :if={@show_modal == :add_domain}
          title="Add Domain"
          subtitle="Assign a domain to a deployment"
          icon="hero-globe-alt"
          on_close="close_modal"
        >
          <.form
            for={@modal_form}
            id="add-domain-form"
            phx-submit="save_domain"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Deployment
              </label>
              <select
                name="add_domain[deployment_id]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                required
              >
                <option value="" disabled selected>Select a deployment...</option>
                <option :for={d <- @deployments_without_domain} value={d.id}>
                  {d.app_template.name} ({d.tenant.name})
                </option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                DNS Zone (optional)
              </label>
              <select
                name="add_domain[dns_zone_id]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              >
                <option value="">None (manual)</option>
                <option :for={z <- @zones} value={z.id}>{z.name}</option>
              </select>
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                Domain
              </label>
              <.input
                field={@modal_form[:domain]}
                type="text"
                placeholder="app.example.com"
                required
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <.modal_actions />
          </.form>
        </.modal>

        <.modal
          :if={@show_modal == :add_record}
          title="Add DNS Record"
          subtitle="Create a DNS record in a zone"
          icon="hero-document-text"
          on_close="close_modal"
        >
          <.form
            for={@modal_form}
            id="add-record-form"
            phx-submit="save_record"
            class="space-y-4"
          >
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Zone</label>
              <select
                name="record[dns_zone_id]"
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                required
              >
                <option value="" disabled selected>Select a zone...</option>
                <option :for={z <- @zones} value={z.id}>{z.name}</option>
              </select>
            </div>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  Name
                </label>
                <.input
                  field={@modal_form[:name]}
                  type="text"
                  placeholder="www"
                  required
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  Type
                </label>
                <select
                  name="record[type]"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                >
                  <option :for={t <- ~w(A AAAA CNAME MX TXT SRV NS)} value={t}>{t}</option>
                </select>
              </div>
            </div>
            <div>
              <label class="block text-sm font-medium text-base-content/70 mb-1.5">Value</label>
              <.input
                field={@modal_form[:value]}
                type="text"
                placeholder="192.168.1.10"
                required
                class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
              />
            </div>
            <div class="grid grid-cols-2 gap-3">
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  TTL
                </label>
                <.input
                  field={@modal_form[:ttl]}
                  type="number"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                />
              </div>
              <div>
                <label class="block text-sm font-medium text-base-content/70 mb-1.5">
                  Scope
                </label>
                <select
                  name="record[scope]"
                  class="w-full rounded-lg bg-base-200 border-0 text-sm text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
                >
                  <option value="public">Public</option>
                  <option value="internal">Internal</option>
                  <option value="both">Both</option>
                </select>
              </div>
            </div>
            <.modal_actions />
          </.form>
        </.modal>
      </div>
    </Layouts.app>
    """
  end

  # --- Tab Components ---

  defp zones_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/40">
          {length(@zones)} zone(s)
        </p>
        <div class="flex items-center gap-2">
          <button
            type="button"
            phx-click="sync_registrar"
            disabled={@syncing}
            class={[
              "flex items-center gap-2 px-4 py-2 rounded-xl text-sm font-medium transition-all duration-200 cursor-pointer",
              "border border-base-content/10 hover:border-primary/30 hover:bg-primary/5 text-base-content/60 hover:text-primary",
              @syncing && "opacity-50 pointer-events-none"
            ]}
          >
            <.icon
              name="hero-arrow-path-mini"
              class={["size-4", @syncing && "animate-spin"]}
            />
            <span>{if @syncing, do: "Syncing...", else: "Sync from Registrar"}</span>
          </button>
          <button
            type="button"
            phx-click="open_add_zone"
            class="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 hover:-translate-y-0.5 transition-all duration-200 cursor-pointer"
          >
            <.icon name="hero-plus-mini" class="size-4" />
            <span>Add Zone</span>
          </button>
        </div>
      </div>

      <div class="rounded-2xl border border-base-content/[0.06] bg-base-100 overflow-hidden">
        <div :if={@zones == []} class="px-6 py-16 text-center">
          <div class="mx-auto w-14 h-14 rounded-2xl bg-base-200/80 flex items-center justify-center mb-4">
            <.icon name="hero-server-stack" class="size-6 text-base-content/20" />
          </div>
          <p class="text-sm font-medium text-base-content/60 mb-1">No DNS zones</p>
          <p class="text-xs text-base-content/35 leading-relaxed max-w-[320px] mx-auto mb-4">
            Add a zone manually or sync from your registrar to get started.
          </p>
        </div>

        <table :if={@zones != []} class="w-full">
          <thead>
            <tr class="border-b border-base-content/[0.06]">
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Zone
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Provider
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Records
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Status
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/[0.04]">
            <tr :for={zone <- @zones} class="hover:bg-base-content/[0.02] transition-colors">
              <td class="px-6 py-4">
                <span class="text-sm font-medium text-base-content font-mono">{zone.name}</span>
              </td>
              <td class="px-6 py-4">
                <.provider_badge provider={zone.provider} />
              </td>
              <td class="px-6 py-4">
                <span class="text-sm text-base-content/50">
                  {length(zone.dns_records)}
                </span>
              </td>
              <td class="px-6 py-4">
                <.sync_status_badge status={zone.sync_status} />
              </td>
              <td class="px-6 py-4 text-right">
                <button
                  type="button"
                  phx-click="delete_zone"
                  phx-value-id={zone.id}
                  data-confirm="Delete this zone and all its records?"
                  class="text-xs text-error/60 hover:text-error transition-colors cursor-pointer"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp domains_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/40">
          {length(@domains)} domain(s)
        </p>
        <button
          type="button"
          phx-click="open_add_domain"
          class="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 hover:-translate-y-0.5 transition-all duration-200 cursor-pointer"
        >
          <.icon name="hero-plus-mini" class="size-4" />
          <span>Add Domain</span>
        </button>
      </div>

      <div class="rounded-2xl border border-base-content/[0.06] bg-base-100 overflow-hidden">
        <div :if={@domains == []} class="px-6 py-16 text-center">
          <div class="mx-auto w-14 h-14 rounded-2xl bg-base-200/80 flex items-center justify-center mb-4">
            <.icon name="hero-globe-alt" class="size-6 text-base-content/20" />
          </div>
          <p class="text-sm font-medium text-base-content/60 mb-1">No domains configured</p>
          <p class="text-xs text-base-content/35 leading-relaxed max-w-[280px] mx-auto mb-4">
            Assign a domain to a deployment to expose it with a custom hostname.
          </p>
        </div>

        <table :if={@domains != []} class="w-full">
          <thead>
            <tr class="border-b border-base-content/[0.06]">
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Domain
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                App
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Zone
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                TLS
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Exposure
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/[0.04]">
            <tr :for={domain <- @domains} class="hover:bg-base-content/[0.02] transition-colors">
              <td class="px-6 py-4">
                <span class="text-sm font-medium text-base-content font-mono">{domain.domain}</span>
              </td>
              <td class="px-6 py-4">
                <div>
                  <span class="text-sm text-base-content">{domain.app_name}</span>
                  <span class="text-xs text-base-content/35 ml-1">({domain.tenant_name})</span>
                </div>
              </td>
              <td class="px-6 py-4">
                <span class={[
                  "text-sm",
                  if(domain.zone_name,
                    do: "text-base-content/70 font-mono",
                    else: "text-base-content/25 italic"
                  )
                ]}>
                  {domain.zone_name || "unlinked"}
                </span>
              </td>
              <td class="px-6 py-4">
                <.tls_badge status={domain.tls_status} />
              </td>
              <td class="px-6 py-4">
                <.exposure_pill mode={domain.exposure_mode} />
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp records_tab(assigns) do
    ~H"""
    <div class="space-y-4">
      <div class="flex items-center justify-between">
        <p class="text-sm text-base-content/40">
          {length(@dns_records)} record(s)
        </p>
        <button
          type="button"
          phx-click="open_add_record"
          class="flex items-center gap-2 px-4 py-2.5 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 hover:-translate-y-0.5 transition-all duration-200 cursor-pointer"
        >
          <.icon name="hero-plus-mini" class="size-4" />
          <span>Add Record</span>
        </button>
      </div>

      <div class="rounded-2xl border border-base-content/[0.06] bg-base-100 overflow-hidden">
        <div :if={@dns_records == []} class="px-6 py-16 text-center">
          <div class="mx-auto w-14 h-14 rounded-2xl bg-base-200/80 flex items-center justify-center mb-4">
            <.icon name="hero-document-text" class="size-6 text-base-content/20" />
          </div>
          <p class="text-sm font-medium text-base-content/60 mb-1">No DNS records</p>
          <p class="text-xs text-base-content/35 leading-relaxed max-w-[320px] mx-auto mb-4">
            Records are created automatically when you deploy with a domain, or you can add them manually.
          </p>
        </div>

        <table :if={@dns_records != []} class="w-full">
          <thead>
            <tr class="border-b border-base-content/[0.06]">
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Name
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Type
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Value
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Zone
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Scope
              </th>
              <th class="text-left text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
                Managed
              </th>
              <th class="text-right text-[11px] font-semibold uppercase tracking-wider text-base-content/35 px-6 py-3">
              </th>
            </tr>
          </thead>
          <tbody class="divide-y divide-base-content/[0.04]">
            <tr
              :for={record <- @dns_records}
              class="hover:bg-base-content/[0.02] transition-colors"
            >
              <td class="px-6 py-4">
                <span class="text-sm font-medium text-base-content font-mono">{record.name}</span>
              </td>
              <td class="px-6 py-4">
                <.type_badge type={record.type} />
              </td>
              <td class="px-6 py-4">
                <span class="text-sm text-base-content/60 font-mono truncate max-w-[200px] block">
                  {record.value}
                </span>
              </td>
              <td class="px-6 py-4">
                <span class="text-sm text-base-content/50 font-mono">{record.zone_name}</span>
              </td>
              <td class="px-6 py-4">
                <.scope_badge scope={record.scope} />
              </td>
              <td class="px-6 py-4">
                <span :if={record.managed} class="text-[11px] font-medium text-success/70">
                  Auto
                </span>
                <span :if={!record.managed} class="text-[11px] font-medium text-base-content/30">
                  Manual
                </span>
              </td>
              <td class="px-6 py-4 text-right">
                <button
                  type="button"
                  phx-click="delete_record"
                  phx-value-id={record.id}
                  data-confirm="Delete this DNS record?"
                  class="text-xs text-error/60 hover:text-error transition-colors cursor-pointer"
                >
                  Delete
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # --- Component Helpers ---

  defp modal(assigns) do
    ~H"""
    <div
      id={"modal-#{@title |> String.downcase() |> String.replace(~r/\s+/, "-")}"}
      class="fixed inset-0 z-50 flex items-center justify-center p-4"
      phx-window-keydown={@on_close}
      phx-key="escape"
    >
      <div class="absolute inset-0 bg-black/50 backdrop-blur-sm" phx-click={@on_close}></div>
      <div class="relative bg-base-100 rounded-2xl shadow-2xl border border-base-content/[0.08] w-full max-w-md overflow-hidden">
        <div class="px-6 pt-6 pb-0">
          <div class="flex items-center gap-4 mb-1">
            <div class="w-11 h-11 rounded-xl bg-primary/10 flex items-center justify-center">
              <.icon name={@icon} class="size-5 text-primary" />
            </div>
            <div>
              <h3 class="text-lg font-bold text-base-content">{@title}</h3>
              <p class="text-xs text-base-content/40">{@subtitle}</p>
            </div>
          </div>
        </div>
        <div class="px-6 py-5">
          {render_slot(@inner_block)}
        </div>
      </div>
    </div>
    """
  end

  defp modal_actions(assigns) do
    assigns = assign_new(assigns, :submit_label, fn -> "Save" end)

    ~H"""
    <div class="flex justify-end gap-3 pt-3 border-t border-base-content/[0.06]">
      <button
        type="button"
        phx-click="close_modal"
        class="px-4 py-2 rounded-xl text-sm font-medium text-base-content/60 hover:text-base-content hover:bg-base-content/5 transition-colors cursor-pointer"
      >
        Cancel
      </button>
      <button
        type="submit"
        class="px-5 py-2 rounded-xl bg-primary text-primary-content text-sm font-semibold shadow-md shadow-primary/25 hover:shadow-lg hover:shadow-primary/30 transition-all cursor-pointer"
      >
        {@submit_label}
      </button>
    </div>
    """
  end

  defp provider_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[11px] font-medium rounded-md px-2 py-0.5",
      provider_classes(@provider)
    ]}>
      {String.capitalize(@provider || "manual")}
    </span>
    """
  end

  defp provider_classes("cloudflare"), do: "bg-orange-500/10 text-orange-600"
  defp provider_classes(_), do: "bg-base-200 text-base-content/40"

  defp sync_status_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[11px] font-medium rounded-md px-2 py-0.5",
      sync_classes(@status)
    ]}>
      <span class={["w-1.5 h-1.5 rounded-full", sync_dot(@status)]}></span>
      {format_sync_status(@status)}
    </span>
    """
  end

  defp sync_classes(:synced), do: "bg-success/10 text-success"
  defp sync_classes(:pending), do: "bg-warning/10 text-warning"
  defp sync_classes(:error), do: "bg-error/10 text-error"
  defp sync_classes(_), do: "bg-base-200 text-base-content/40"

  defp sync_dot(:synced), do: "bg-success"
  defp sync_dot(:pending), do: "bg-warning"
  defp sync_dot(:error), do: "bg-error"
  defp sync_dot(_), do: "bg-base-content/30"

  defp format_sync_status(:synced), do: "Synced"
  defp format_sync_status(:pending), do: "Pending"
  defp format_sync_status(:error), do: "Error"
  defp format_sync_status(s), do: to_string(s)

  defp tls_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[11px] font-medium rounded-md px-2 py-0.5",
      tls_classes(@status)
    ]}>
      <.icon name={tls_icon(@status)} class="size-3" />
      {format_tls(@status)}
    </span>
    """
  end

  defp tls_classes(:active), do: "bg-success/10 text-success"
  defp tls_classes(:pending), do: "bg-warning/10 text-warning"
  defp tls_classes(:expired), do: "bg-error/10 text-error"
  defp tls_classes(:failed), do: "bg-error/10 text-error"
  defp tls_classes(_), do: "bg-base-200 text-base-content/40"

  defp tls_icon(:active), do: "hero-lock-closed-mini"
  defp tls_icon(:pending), do: "hero-clock-mini"
  defp tls_icon(:expired), do: "hero-exclamation-triangle-mini"
  defp tls_icon(:failed), do: "hero-x-circle-mini"
  defp tls_icon(_), do: "hero-question-mark-circle-mini"

  defp format_tls(:active), do: "Active"
  defp format_tls(:pending), do: "Pending"
  defp format_tls(:expired), do: "Expired"
  defp format_tls(:failed), do: "Failed"
  defp format_tls(_), do: "Unknown"

  defp scope_badge(assigns) do
    ~H"""
    <span class={[
      "inline-flex items-center gap-1 text-[11px] font-medium rounded-md px-2 py-0.5",
      scope_classes(@scope)
    ]}>
      <.icon name={scope_icon(@scope)} class="size-3" />
      {format_scope(@scope)}
    </span>
    """
  end

  defp scope_classes(:public), do: "bg-info/10 text-info"
  defp scope_classes(:internal), do: "bg-warning/10 text-warning"
  defp scope_classes(:both), do: "bg-primary/10 text-primary"
  defp scope_classes(_), do: "bg-base-200 text-base-content/40"

  defp scope_icon(:public), do: "hero-globe-alt-mini"
  defp scope_icon(:internal), do: "hero-home-mini"
  defp scope_icon(:both), do: "hero-arrows-right-left-mini"
  defp scope_icon(_), do: "hero-question-mark-circle-mini"

  defp format_scope(:public), do: "Public"
  defp format_scope(:internal), do: "Internal"
  defp format_scope(:both), do: "Both"
  defp format_scope(s), do: to_string(s)

  defp type_badge(assigns) do
    ~H"""
    <span class="inline-flex items-center text-[11px] font-bold rounded px-1.5 py-0.5 bg-base-200/80 text-base-content/60 font-mono tracking-wide">
      {@type}
    </span>
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
  defp exposure_classes(_), do: "bg-base-200 text-base-content/40"

  defp exposure_icon(:private), do: "hero-lock-closed-mini"
  defp exposure_icon(:sso_protected), do: "hero-shield-check-mini"
  defp exposure_icon(:public), do: "hero-globe-alt-mini"
  defp exposure_icon(_), do: "hero-question-mark-circle-mini"

  defp format_exposure(:sso_protected), do: "SSO"
  defp format_exposure(:private), do: "Private"
  defp format_exposure(:public), do: "Public"
  defp format_exposure(mode), do: to_string(mode)

  defp tab_label("zones"), do: "DNS Zones"
  defp tab_label("domains"), do: "Domains"
  defp tab_label("records"), do: "DNS Records"
  defp tab_label(t), do: t
end
