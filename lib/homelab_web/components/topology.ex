defmodule HomelabWeb.Topology do
  @moduledoc """
  Visual infrastructure topology component rendering services as a
  three-column layout: Gateway | Services | Infrastructure.

  Two rendering modes:
  - `topology/1` — readonly view with status indicators and click-to-navigate
  - `topology_editor/1` — editable view with searchable dropdowns and add/remove actions
  """
  use Phoenix.Component

  import HomelabWeb.CoreComponents, only: [icon: 1]

  # ============================================================
  # Readonly topology
  # ============================================================

  attr :nodes, :list, required: true
  attr :edges, :list, default: []
  attr :highlight, :string, default: nil

  def topology(assigns) do
    grouped = group_nodes(assigns.nodes)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-0 rounded-lg border border-base-content/[0.06] bg-base-200/30 overflow-hidden">
      <.topology_column
        label="Gateway"
        icon="hero-shield-check"
        nodes={@grouped.gateway}
        edges={@edges}
        highlight={@highlight}
        color="info"
        mode={:readonly}
      />
      <.topology_column
        label="Services"
        icon="hero-cube"
        nodes={@grouped.services}
        edges={@edges}
        highlight={@highlight}
        color="primary"
        mode={:readonly}
      />
      <.topology_column
        label="Infrastructure"
        icon="hero-circle-stack"
        nodes={@grouped.infra}
        edges={@edges}
        highlight={@highlight}
        color="secondary"
        mode={:readonly}
      />
    </div>
    """
  end

  # ============================================================
  # Editable topology
  # ============================================================

  attr :nodes, :list, required: true
  attr :edges, :list, default: []
  attr :on_change, :string, default: "topology_change"
  attr :on_add, :string, default: "topology_add"
  attr :on_remove, :string, default: "topology_remove"

  def topology_editor(assigns) do
    grouped = group_nodes(assigns.nodes)
    assigns = assign(assigns, :grouped, grouped)

    ~H"""
    <div class="grid grid-cols-1 lg:grid-cols-3 gap-0 rounded-lg border border-base-content/[0.06] bg-base-200/30 overflow-hidden">
      <.topology_column
        label="Gateway"
        icon="hero-shield-check"
        nodes={@grouped.gateway}
        edges={@edges}
        color="info"
        mode={:editable}
        on_change={@on_change}
        on_add={@on_add}
        on_remove={@on_remove}
        add_label="Add gateway"
      />
      <.topology_column
        label="Services"
        icon="hero-cube"
        nodes={@grouped.services}
        edges={@edges}
        color="primary"
        mode={:editable}
        on_change={@on_change}
        on_add={@on_add}
        on_remove={@on_remove}
        add_label="Add service"
      />
      <.topology_column
        label="Infrastructure"
        icon="hero-circle-stack"
        nodes={@grouped.infra}
        edges={@edges}
        color="secondary"
        mode={:editable}
        on_change={@on_change}
        on_add={@on_add}
        on_remove={@on_remove}
        add_label="Add database / cache"
      />
    </div>
    """
  end

  # ============================================================
  # Column
  # ============================================================

  attr :label, :string, required: true
  attr :icon, :string, required: true
  attr :nodes, :list, required: true
  attr :edges, :list, default: []
  attr :highlight, :string, default: nil
  attr :color, :string, required: true
  attr :mode, :atom, required: true
  attr :on_change, :string, default: nil
  attr :on_add, :string, default: nil
  attr :on_remove, :string, default: nil
  attr :add_label, :string, default: "Add"

  defp topology_column(assigns) do
    ~H"""
    <div class="flex flex-col border-r border-base-content/[0.06] last:border-r-0">
      <div class="flex items-center gap-2 px-4 py-2 border-b border-base-content/[0.06] bg-base-100/50">
        <.icon name={@icon} class={"size-4 text-#{@color}"} />
        <span class="text-xs font-semibold text-base-content/60 uppercase tracking-wider">
          {@label}
        </span>
        <span :if={@nodes != []} class="text-[10px] text-base-content/30 ml-auto">
          {length(@nodes)}
        </span>
      </div>

      <div class="flex-1 p-3 space-y-2">
        <%= if @nodes == [] do %>
          <div class="flex items-center justify-center py-8">
            <p class="text-xs text-base-content/20 italic">No {@label |> String.downcase()}</p>
          </div>
        <% else %>
          <%= for node <- @nodes do %>
            <.topology_node
              node={node}
              highlight={@highlight}
              mode={@mode}
              on_change={@on_change}
              on_remove={@on_remove}
              edges={Enum.filter(@edges, fn e -> e.from == node.id or e.to == node.id end)}
            />
          <% end %>
        <% end %>
      </div>

      <div :if={@mode == :editable} class="px-4 pb-4">
        <button
          type="button"
          phx-click={@on_add}
          phx-value-column={@label |> String.downcase()}
          class="w-full py-2.5 rounded-lg border-2 border-dashed border-base-content/10 text-xs font-medium text-base-content/30 hover:border-base-content/20 hover:text-base-content/50 transition-colors cursor-pointer flex items-center justify-center gap-1.5"
        >
          <.icon name="hero-plus-mini" class="size-3.5" /> {@add_label}
        </button>
      </div>
    </div>
    """
  end

  # ============================================================
  # Node card
  # ============================================================

  attr :node, :map, required: true
  attr :highlight, :string, default: nil
  attr :mode, :atom, required: true
  attr :on_change, :string, default: nil
  attr :on_remove, :string, default: nil
  attr :edges, :list, default: []

  defp topology_node(assigns) do
    faded? = assigns.highlight != nil and assigns.highlight != assigns.node.id
    assigns = assign(assigns, :faded?, faded?)

    ~H"""
    <div class={[
      "rounded-lg border bg-base-100 overflow-hidden transition-all",
      type_border_color(@node.type),
      if(@faded?, do: "opacity-40", else: "")
    ]}>
      <%!-- Header --%>
      <div
        class={[
          "flex items-center gap-3 px-3 py-2",
          if(@node[:navigate] && @mode == :readonly,
            do: "cursor-pointer hover:bg-base-200/50 transition-colors",
            else: ""
          )
        ]}
        phx-click={if(@node[:navigate] && @mode == :readonly, do: "navigate", else: nil)}
        phx-value-to={if(@node[:navigate] && @mode == :readonly, do: @node.navigate, else: nil)}
      >
        <div class={"w-8 h-8 rounded-lg flex items-center justify-center flex-shrink-0 #{type_bg(@node.type)}"}>
          <.icon name={@node.icon} class={"size-4 #{type_icon_color(@node.type)}"} />
        </div>
        <div class="flex-1 min-w-0">
          <div class="flex items-center gap-2">
            <span class="text-sm font-semibold text-base-content truncate">{@node.label}</span>
            <span
              :if={@node[:badge]}
              class={"inline-flex px-1.5 py-0.5 rounded text-[9px] font-bold uppercase tracking-wide #{badge_classes(@node.type)}"}
            >
              {@node.badge}
            </span>
          </div>
          <p :if={@node[:subtitle]} class="text-[11px] text-base-content/40 font-mono truncate">
            {@node.subtitle}
          </p>
        </div>
        <.status_dot :if={@node[:status]} status={@node.status} />
        <button
          :if={@mode == :editable}
          type="button"
          phx-click={@on_remove}
          phx-value-node-id={@node.id}
          class="text-base-content/20 hover:text-error transition-colors cursor-pointer ml-1"
        >
          <.icon name="hero-x-mark-mini" class="size-4" />
        </button>
      </div>

      <%!-- Properties --%>
      <div
        :if={@node[:properties] && @node.properties != []}
        class="border-t border-base-content/[0.04]"
      >
        <%= for prop <- @node.properties do %>
          <div class="flex items-center justify-between px-3 py-1.5 border-b border-base-content/[0.03] last:border-b-0">
            <span class="text-[11px] text-base-content/40 flex items-center gap-1.5">
              <.icon :if={prop[:icon]} name={prop.icon} class="size-3 text-base-content/25" />
              {prop.label}
            </span>
            <%= if @mode == :editable && prop[:editable] && prop[:options] do %>
              <.property_select node_id={@node.id} prop={prop} on_change={@on_change} />
            <% else %>
              <span class="text-[11px] font-medium text-base-content/60">{prop.value}</span>
            <% end %>
          </div>
        <% end %>
      </div>

      <%!-- Edge labels --%>
      <div :if={@edges != []} class="px-4 py-1.5 bg-base-200/30 border-t border-base-content/[0.04]">
        <div class="flex flex-wrap gap-2">
          <span :for={edge <- @edges} class="text-[9px] text-base-content/30 flex items-center gap-1">
            <.icon name="hero-arrows-right-left-mini" class="size-2.5" />
            {edge[:label] || "connected"}
          </span>
        </div>
      </div>
    </div>
    """
  end

  # ============================================================
  # Property select (editable mode)
  # ============================================================

  attr :node_id, :string, required: true
  attr :prop, :map, required: true
  attr :on_change, :string, required: true

  defp property_select(assigns) do
    ~H"""
    <div
      id={"select-#{@node_id}-#{@prop.key}"}
      phx-hook=".SearchSelect"
      phx-update="ignore"
      class="relative"
      data-node-id={@node_id}
      data-prop-key={@prop.key}
      data-event={@on_change}
    >
      <button
        type="button"
        class="search-select-trigger flex items-center gap-1 px-2 py-0.5 rounded bg-base-200/80 text-[11px] font-medium text-base-content/60 hover:bg-base-200 transition-colors cursor-pointer"
      >
        <span class="search-select-value">{display_option(@prop.options, @prop.value)}</span>
        <.icon name="hero-chevron-up-down-mini" class="size-3 text-base-content/30" />
      </button>
      <div class="search-select-dropdown hidden absolute right-0 top-full mt-1 z-50 w-48 rounded-lg bg-base-100 border border-base-content/10 shadow-xl overflow-hidden">
        <input
          type="text"
          placeholder="Search..."
          class="search-select-input w-full border-0 border-b border-base-content/[0.06] bg-transparent text-xs text-base-content px-3 py-2 focus:ring-0 focus:outline-none"
        />
        <div class="search-select-list max-h-40 overflow-y-auto py-1">
          <button
            :for={{label, value} <- @prop.options}
            type="button"
            data-value={value}
            class={[
              "search-select-option w-full text-left px-3 py-1.5 text-xs hover:bg-base-200/80 transition-colors cursor-pointer",
              if(value == @prop.value, do: "text-primary font-semibold", else: "text-base-content/60")
            ]}
          >
            {label}
          </button>
        </div>
      </div>
    </div>
    <script :type={Phoenix.LiveView.ColocatedHook} name=".SearchSelect">
      export default {
        mounted() {
          const el = this.el
          const trigger = el.querySelector('.search-select-trigger')
          const dropdown = el.querySelector('.search-select-dropdown')
          const input = el.querySelector('.search-select-input')
          const valueDisplay = el.querySelector('.search-select-value')
          const options = el.querySelectorAll('.search-select-option')

          let open = false

          const toggle = () => {
            open = !open
            dropdown.classList.toggle('hidden', !open)
            if (open) { input.value = ''; filterOptions(''); input.focus() }
          }

          const close = () => {
            open = false
            dropdown.classList.add('hidden')
          }

          const filterOptions = (q) => {
            const lower = q.toLowerCase()
            options.forEach(opt => {
              opt.style.display = opt.textContent.toLowerCase().includes(lower) ? '' : 'none'
            })
          }

          trigger.addEventListener('click', (e) => { e.stopPropagation(); toggle() })
          input.addEventListener('input', (e) => filterOptions(e.target.value))
          input.addEventListener('keydown', (e) => { if (e.key === 'Escape') close() })

          options.forEach(opt => {
            opt.addEventListener('click', (e) => {
              e.stopPropagation()
              const value = opt.dataset.value
              valueDisplay.textContent = opt.textContent.trim()
              close()
              this.pushEvent(el.dataset.event, {
                node_id: el.dataset.nodeId,
                key: el.dataset.propKey,
                value: value
              })
            })
          })

          document.addEventListener('click', (e) => {
            if (!el.contains(e.target)) close()
          })
        }
      }
    </script>
    """
  end

  # ============================================================
  # Status dot
  # ============================================================

  attr :status, :atom, required: true

  defp status_dot(assigns) do
    ~H"""
    <span class="relative flex items-center gap-1.5">
      <span class={[
        "w-2 h-2 rounded-full flex-shrink-0",
        status_color(@status)
      ]} />
      <span class="text-[10px] text-base-content/30 capitalize">{@status}</span>
    </span>
    """
  end

  # ============================================================
  # Data conversion helpers
  # ============================================================

  @doc """
  Builds topology nodes and edges from deploy wizard assigns.
  """
  def from_wizard_state(assigns) do
    template = assigns[:selected_template]
    compose_services = assigns[:compose_services] || []
    domain = assigns[:domain] || ""
    exposure = assigns[:exposure_mode] || "public"
    ports = assigns[:ports] || []

    nodes = []
    edges = []

    {nodes, edges} =
      if domain != "" do
        gateway = %{
          id: "gateway",
          label: "Traefik",
          type: :gateway,
          status: nil,
          icon: "hero-shield-check",
          subtitle: domain,
          badge: "Gateway",
          properties: [
            %{key: "domain", label: "Domain", value: domain, icon: "hero-globe-alt-mini"},
            %{
              key: "exposure",
              label: "Exposure",
              value: format_exposure(exposure),
              editable: true,
              icon: "hero-lock-closed-mini",
              options: [
                {"Public", "public"},
                {"SSO Protected", "sso_protected"},
                {"Private", "private"},
                {"Service", "service"}
              ]
            },
            %{key: "ssl", label: "SSL", value: "Let's Encrypt", icon: "hero-shield-check-mini"}
          ]
        }

        {[gateway | nodes], edges}
      else
        {nodes, edges}
      end

    {nodes, edges} =
      if template do
        web_ports = Enum.filter(ports, fn p -> p["role"] == "web" end)
        _db_ports = Enum.filter(ports, fn p -> p["role"] == "database" end)
        port_summary = Enum.map_join(ports, ", ", fn p -> "#{p["internal"]}" end)

        app = %{
          id: "app-#{template.slug || "main"}",
          label: template.name || "Application",
          type: :service,
          status: nil,
          icon: "hero-cube",
          subtitle: template.image,
          badge: if(web_ports != [], do: "Web", else: "App"),
          properties: [
            %{
              key: "image",
              label: "Image",
              value: image_short(template.image),
              icon: "hero-cube-mini"
            },
            %{
              key: "ports",
              label: "Ports",
              value: if(port_summary != "", do: port_summary, else: "None"),
              icon: "hero-signal-mini"
            }
          ]
        }

        app_edges =
          if domain != "" do
            [%{from: "gateway", to: app.id, label: "HTTPS :443"}]
          else
            []
          end

        {nodes ++ [app], edges ++ app_edges}
      else
        {nodes, edges}
      end

    {nodes, edges} =
      Enum.reduce(compose_services, {nodes, edges}, fn svc, {n, e} ->
        svc_type = classify_image(svc[:image] || svc.image)
        svc_id = "svc-#{svc[:name] || svc.name}"

        svc_ports = svc[:ports] || []
        port_str = Enum.map_join(svc_ports, ", ", fn p -> "#{p["internal"]}" end)

        node = %{
          id: svc_id,
          label: svc[:name] || svc.name,
          type: svc_type,
          status: nil,
          icon: type_icon(svc_type),
          subtitle: svc[:image] || svc.image,
          badge: type_badge(svc_type),
          properties:
            [
              %{
                key: "image",
                label: "Image",
                value: image_short(svc[:image] || svc.image),
                icon: "hero-cube-mini"
              }
            ] ++
              if(port_str != "",
                do: [%{key: "ports", label: "Ports", value: port_str, icon: "hero-signal-mini"}],
                else: []
              )
        }

        deps = svc[:depends_on] || []

        dep_edges =
          Enum.map(deps, fn dep -> %{from: svc_id, to: "svc-#{dep}", label: "depends"} end)

        main_app_id = if template, do: "app-#{template.slug || "main"}", else: nil

        infra_edge =
          if main_app_id && svc_type in [:database, :cache] do
            [%{from: main_app_id, to: svc_id, label: type_badge(svc_type)}]
          else
            []
          end

        {n ++ [node], e ++ dep_edges ++ infra_edge}
      end)

    %{nodes: nodes, edges: edges}
  end

  @doc """
  Builds topology from a deployment and its tenant siblings.
  """
  def from_deployment(deployment, siblings) do
    all = [deployment | Enum.reject(siblings, &(&1.id == deployment.id))]
    nodes = Enum.map(all, &deployment_to_node/1)

    has_domain? = Enum.any?(all, fn d -> d.domain && d.domain != "" end)

    gateway_nodes =
      if has_domain? do
        domains =
          all
          |> Enum.map(& &1.domain)
          |> Enum.filter(& &1)
          |> Enum.filter(&(&1 != ""))
          |> Enum.join(", ")

        [
          %{
            id: "gateway",
            label: "Traefik",
            type: :gateway,
            status: :active,
            icon: "hero-shield-check",
            subtitle: domains,
            badge: "Gateway",
            properties: [
              %{
                key: "routing",
                label: "Routing",
                value:
                  "#{length(Enum.filter(all, fn d -> d.domain && d.domain != "" end))} routes",
                icon: "hero-arrows-right-left-mini"
              }
            ]
          }
        ]
      else
        []
      end

    edges =
      all
      |> Enum.filter(fn d -> d.domain && d.domain != "" end)
      |> Enum.map(fn d ->
        %{from: "gateway", to: "dep-#{d.id}", label: d.domain}
      end)

    dep_edges =
      all
      |> Enum.flat_map(fn d ->
        (d.app_template.depends_on || [])
        |> Enum.map(fn dep_slug ->
          target = Enum.find(all, fn s -> s.app_template.slug == dep_slug end)

          if target,
            do: %{from: "dep-#{d.id}", to: "dep-#{target.id}", label: "depends"},
            else: nil
        end)
        |> Enum.reject(&is_nil/1)
      end)

    %{nodes: gateway_nodes ++ nodes, edges: edges ++ dep_edges, highlight: "dep-#{deployment.id}"}
  end

  @doc """
  Builds topology from all deployments in a tenant.
  """
  def from_tenant(deployments) do
    nodes = Enum.map(deployments, &deployment_to_node/1)

    has_domain? = Enum.any?(deployments, fn d -> d.domain && d.domain != "" end)

    gateway_nodes =
      if has_domain? do
        domain_count = Enum.count(deployments, fn d -> d.domain && d.domain != "" end)

        [
          %{
            id: "gateway",
            label: "Traefik",
            type: :gateway,
            status: :active,
            icon: "hero-shield-check",
            subtitle: "Reverse proxy",
            badge: "Gateway",
            properties: [
              %{
                key: "routes",
                label: "Routes",
                value: "#{domain_count}",
                icon: "hero-arrows-right-left-mini"
              }
            ]
          }
        ]
      else
        []
      end

    edges =
      deployments
      |> Enum.filter(fn d -> d.domain && d.domain != "" end)
      |> Enum.map(fn d ->
        %{from: "gateway", to: "dep-#{d.id}", label: d.domain}
      end)

    dep_edges =
      deployments
      |> Enum.flat_map(fn d ->
        (d.app_template.depends_on || [])
        |> Enum.map(fn dep_slug ->
          target = Enum.find(deployments, fn s -> s.app_template.slug == dep_slug end)

          if target,
            do: %{from: "dep-#{d.id}", to: "dep-#{target.id}", label: "depends"},
            else: nil
        end)
        |> Enum.reject(&is_nil/1)
      end)

    %{nodes: gateway_nodes ++ nodes, edges: edges ++ dep_edges}
  end

  # ============================================================
  # Classification
  # ============================================================

  @gateway_patterns ~w(traefik nginx caddy haproxy envoy)
  @database_patterns ~w(postgres mysql mariadb mongo cockroach sqlite)
  @cache_patterns ~w(redis memcached valkey dragonfly keydb)
  @storage_patterns ~w(minio seaweedfs garage lakeFS)

  @doc """
  Classifies a Docker image into a node type based on image name patterns.
  """
  def classify_image(nil), do: :service
  def classify_image(""), do: :service

  def classify_image(image) do
    lower = String.downcase(image)

    cond do
      Enum.any?(@gateway_patterns, &String.contains?(lower, &1)) -> :gateway
      Enum.any?(@database_patterns, &String.contains?(lower, &1)) -> :database
      Enum.any?(@cache_patterns, &String.contains?(lower, &1)) -> :cache
      Enum.any?(@storage_patterns, &String.contains?(lower, &1)) -> :storage
      true -> :service
    end
  end

  # ============================================================
  # Internal helpers
  # ============================================================

  defp group_nodes(nodes) do
    gateway = Enum.filter(nodes, fn n -> n.type == :gateway end)
    infra = Enum.filter(nodes, fn n -> n.type in [:database, :cache, :storage] end)

    services =
      Enum.filter(nodes, fn n -> n.type not in [:gateway, :database, :cache, :storage] end)

    %{gateway: gateway, services: services, infra: infra}
  end

  defp deployment_to_node(d) do
    node_type = classify_image(d.app_template.image)
    ports = d.app_template.ports || []
    port_roles = ports |> Enum.map(fn p -> p["role"] end) |> Enum.filter(& &1) |> Enum.uniq()
    has_web? = "web" in port_roles

    node_type =
      cond do
        "database" in port_roles -> :database
        node_type != :service -> node_type
        true -> :service
      end

    props = [
      %{
        key: "image",
        label: "Image",
        value: image_short(d.app_template.image),
        icon: "hero-cube-mini"
      }
    ]

    props =
      if d.domain && d.domain != "" do
        props ++ [%{key: "domain", label: "Domain", value: d.domain, icon: "hero-globe-alt-mini"}]
      else
        props
      end

    props =
      if d.app_template.exposure_mode do
        props ++
          [
            %{
              key: "exposure",
              label: "Exposure",
              value: format_exposure(to_string(d.app_template.exposure_mode)),
              icon: "hero-lock-closed-mini"
            }
          ]
      else
        props
      end

    %{
      id: "dep-#{d.id}",
      label: d.app_template.name,
      type: node_type,
      status: map_status(d.status),
      icon: type_icon(node_type),
      subtitle: d.app_template.image,
      badge: if(has_web?, do: "Web", else: type_badge(node_type)),
      properties: props,
      navigate: "/deployments/#{d.id}"
    }
  end

  defp map_status(:running), do: :active
  defp map_status(:pending), do: :pending
  defp map_status(:deploying), do: :pending
  defp map_status(:stopped), do: :stopped
  defp map_status(:failed), do: :failed
  defp map_status(:removing), do: :stopped
  defp map_status(_), do: nil

  defp status_color(:active), do: "bg-success"
  defp status_color(:pending), do: "bg-warning"
  defp status_color(:failed), do: "bg-error"
  defp status_color(:stopped), do: "bg-base-content/30"
  defp status_color(_), do: "bg-base-content/10"

  defp type_border_color(:gateway),
    do:
      "border-l-4 border-l-info border-t-base-content/[0.06] border-r-base-content/[0.06] border-b-base-content/[0.06]"

  defp type_border_color(:service),
    do:
      "border-l-4 border-l-primary border-t-base-content/[0.06] border-r-base-content/[0.06] border-b-base-content/[0.06]"

  defp type_border_color(:database),
    do:
      "border-l-4 border-l-secondary border-t-base-content/[0.06] border-r-base-content/[0.06] border-b-base-content/[0.06]"

  defp type_border_color(:cache),
    do:
      "border-l-4 border-l-accent border-t-base-content/[0.06] border-r-base-content/[0.06] border-b-base-content/[0.06]"

  defp type_border_color(:storage),
    do:
      "border-l-4 border-l-warning border-t-base-content/[0.06] border-r-base-content/[0.06] border-b-base-content/[0.06]"

  defp type_border_color(_), do: "border border-base-content/[0.06]"

  defp type_bg(:gateway), do: "bg-info/10"
  defp type_bg(:service), do: "bg-primary/10"
  defp type_bg(:database), do: "bg-secondary/10"
  defp type_bg(:cache), do: "bg-accent/10"
  defp type_bg(:storage), do: "bg-warning/10"
  defp type_bg(_), do: "bg-base-200"

  defp type_icon_color(:gateway), do: "text-info"
  defp type_icon_color(:service), do: "text-primary"
  defp type_icon_color(:database), do: "text-secondary"
  defp type_icon_color(:cache), do: "text-accent"
  defp type_icon_color(:storage), do: "text-warning"
  defp type_icon_color(_), do: "text-base-content/40"

  defp badge_classes(:gateway), do: "bg-info/10 text-info"
  defp badge_classes(:service), do: "bg-primary/10 text-primary"
  defp badge_classes(:database), do: "bg-secondary/10 text-secondary"
  defp badge_classes(:cache), do: "bg-accent/10 text-accent"
  defp badge_classes(:storage), do: "bg-warning/10 text-warning"
  defp badge_classes(_), do: "bg-base-200 text-base-content/40"

  defp type_icon(:gateway), do: "hero-shield-check"
  defp type_icon(:service), do: "hero-cube"
  defp type_icon(:database), do: "hero-circle-stack"
  defp type_icon(:cache), do: "hero-bolt"
  defp type_icon(:storage), do: "hero-archive-box"
  defp type_icon(_), do: "hero-cog-6-tooth"

  defp type_badge(:gateway), do: "Gateway"
  defp type_badge(:service), do: "App"
  defp type_badge(:database), do: "Database"
  defp type_badge(:cache), do: "Cache"
  defp type_badge(:storage), do: "Storage"
  defp type_badge(_), do: "Service"

  defp format_exposure("public"), do: "Public"
  defp format_exposure("sso_protected"), do: "SSO Protected"
  defp format_exposure("private"), do: "Private"
  defp format_exposure("service"), do: "Service"
  defp format_exposure(other), do: to_string(other)

  defp image_short(nil), do: ""

  defp image_short(image) do
    image
    |> String.split("/")
    |> List.last()
    |> then(fn name ->
      case String.split(name, ":") do
        [n, tag] -> "#{n}:#{tag}"
        [n] -> n
        _ -> name
      end
    end)
  end

  defp display_option(options, current_value) do
    case Enum.find(options, fn {_label, val} -> val == current_value end) do
      {label, _} -> label
      nil -> current_value || "—"
    end
  end
end
