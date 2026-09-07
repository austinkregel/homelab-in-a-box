defmodule HomelabWeb.DeploymentSettings do
  @moduledoc """
  The Settings tab: one form over the whole configuration of a deployment.

  It used to be three forms with three Save buttons — version, runtime, network — each
  recreating the container on its own. An edit that spanned two of them recreated the
  container twice, and nothing on the page could say what the combined change was.

  ## What each card is for

    * **How it's reached** — the derived summary. Not a control: it restates the ports
      and routes below as the sentences an operator actually wants ("published on
      0.0.0.0:2222", "https://git.example.com → :3000"), so the answer to "can I get to
      this?" does not have to be reassembled from three tables.
    * **Version** — the image, and the tags the registry offers.
    * **Network** — the namespace, one ports table, one routes table.
    * **Runtime** — restart, replicas, argv, and the kernel privileges.
    * **Resources** — limits, GPU and the readiness probe.

  Everything is rendered from a `SettingsForm`, and every value shown is the EFFECTIVE
  one. A control that reads "inherit" tells the operator nothing they did not already
  know and hides the one thing they came to find out, so the catalog's own command is
  typed into the field and every capability is listed with the ones that are on ticked.
  Whether that value is stored as an override is settled at save time by comparison —
  see `SettingsForm.override_or_inherit/3`.
  """

  use HomelabWeb, :html

  alias Homelab.Deployments.Findings
  alias Homelab.Deployments.GpuSpec
  alias Homelab.Deployments.Netns
  alias Homelab.Deployments.RuntimeSpec
  alias Homelab.Deployments.SettingsForm

  @restart_policies [
    {"on-failure", "On failure (up to 3 times)"},
    {"always", "Always"},
    {"unless-stopped", "Unless stopped"},
    {"no", "Never"}
  ]

  @auth_choices [
    {"public", "None"},
    {"sso_protected", "SSO"},
    {"private", "LAN only"}
  ]

  attr :form, SettingsForm, required: true
  attr :base, SettingsForm, required: true
  attr :deployment, :map, required: true
  attr :editing, :boolean, default: false
  attr :netns_candidates, :list, default: []
  attr :gpu_kinds, :list, default: []
  attr :available_tags, :any, default: :idle
  attr :review, :list, default: nil
  attr :netns_donor, :any, default: nil
  attr :netns_children, :list, default: []
  attr :netns_donor_env, :map, default: %{}

  def settings_tab(assigns) do
    assigns =
      assigns
      |> assign(:diff, SettingsForm.diff(assigns.base, assigns.form))
      |> assign(:network_findings, Findings.network(assigns.form))
      |> assign(:health_findings, Findings.health(assigns.form))

    ~H"""
    <.form
      for={%{}}
      id="settings-form"
      phx-change="settings_changed"
      phx-submit="save_settings"
      class="flex flex-col gap-4"
    >
      <.summary form={@form} deployment={@deployment} netns_candidates={@netns_candidates} />
      <.version_card
        form={@form}
        base={@base}
        deployment={@deployment}
        editing={@editing}
        tags={@available_tags}
      />
      <.network_card
        form={@form}
        deployment={@deployment}
        editing={@editing}
        netns_candidates={@netns_candidates}
        findings={@network_findings}
        netns_donor={@netns_donor}
        netns_children={@netns_children}
        netns_donor_env={@netns_donor_env}
      />
      <.runtime_card form={@form} deployment={@deployment} editing={@editing} />
      <.resources_card
        form={@form}
        editing={@editing}
        gpu_kinds={@gpu_kinds}
        findings={@health_findings}
      />
      <.save_bar :if={@editing} diff={@diff} />
    </.form>

    <.review_sheet :if={@review} deployment={@deployment} rows={@review} />
    """
  end

  # ------------------------------------------------------------------
  # Summary
  # ------------------------------------------------------------------

  # Derived from the tables below rather than stored, so it cannot describe a
  # configuration the form does not hold.
  defp summary(assigns) do
    assigns =
      assigns
      |> assign(:exposure, SettingsForm.exposure(assigns.form))
      |> assign(:lines, summary_lines(assigns.form))

    ~H"""
    <div class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden">
      <div class="flex items-center gap-2.5 flex-wrap px-4 py-3 border-b border-base-content/5">
        <span class="text-sm font-semibold text-base-content">How it's reached</span>
        <span class={["px-2 py-0.5 rounded-full text-[11px] font-medium", exposure_pill(@exposure)]}>
          {exposure_label(@exposure)}
        </span>
        <span
          :if={@form.namespace == "donor"}
          class="px-2 py-0.5 rounded-full text-[11px] font-medium bg-base-200 text-base-content/60"
        >
          via {donor_name(@netns_candidates, @form.donor_id)}
        </span>
        <span
          :if={@form.namespace == "host"}
          class="px-2 py-0.5 rounded-full text-[11px] font-medium bg-base-200 text-base-content/60"
        >
          host namespace
        </span>
      </div>

      <div class="px-4 py-3 flex flex-col gap-1.5">
        <div
          :for={{key, value} <- @lines}
          class="grid grid-cols-[5.75rem_minmax(0,1fr)] gap-3 items-baseline"
        >
          <span class="text-[10px] font-semibold tracking-wider uppercase text-base-content/40">
            {key}
          </span>
          <span class="font-mono text-xs text-base-content break-words">{value}</span>
        </div>
        <p :if={@lines == []} class="text-xs text-base-content/50 leading-relaxed">
          Not reachable from anywhere. Nothing is published and no route points at it — only
          containers on its own network can talk to it.
        </p>
      </div>
    </div>
    """
  end

  defp summary_lines(form) do
    routes =
      for route <- SettingsForm.live_routes(form) do
        {"Route",
         "https://#{route["host"]}#{route["path_prefix"]} → :#{blank(route["port"], "?")}"}
      end

    published =
      for port <- form.ports, port["exposure"] == "host", present?(port["internal"]) do
        if form.namespace == "host" do
          {"On host",
           ":#{port["internal"]} #{upcase(port["protocol"])} — shared namespace, nothing mapped"}
        else
          binding = "#{port["host_ip"] || "0.0.0.0"}:#{blank(port["external"], port["internal"])}"
          {"Published", "#{binding} → :#{port["internal"]} #{upcase(port["protocol"])}"}
        end
      end

    unreachable =
      for port <- form.ports,
          port["exposure"] == "proxy",
          not SettingsForm.routed?(form, port["internal"]) do
        {"Unreachable", ":#{port["internal"]} — set to proxied, but no route points here"}
      end

    routes ++ published ++ unreachable
  end

  # ------------------------------------------------------------------
  # Version
  # ------------------------------------------------------------------

  defp version_card(assigns) do
    ~H"""
    <.card title="Version">
      <div :if={@editing} class="flex flex-col gap-1.5">
        <label for="settings-image" class="text-xs font-medium text-base-content/50">
          Image reference
        </label>
        <input
          type="text"
          id="settings-image"
          name="settings[image]"
          value={@form.image}
          autocomplete="off"
          class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono text-base-content py-2.5 px-3 focus:ring-2 focus:ring-primary/50"
        />
        <p class="text-xs text-base-content/40">
          The catalog default is <span class="font-mono">{@deployment.app_template.image}</span>. Clearing this field
          follows the catalog again.
        </p>
      </div>

      <%!-- Said BEFORE the operator commits, because the expensive half of this mistake
            -- skipping an app's required intermediate versions -- is not recoverable
            from this screen. Shown only when the image actually moved: a version change
            is not a port tweak, and every other edit on this page is. --%>
      <div
        :if={@editing && @form.image != @base.image}
        class="rounded-lg bg-warning/5 border border-warning/20 p-3 flex flex-col gap-1"
      >
        <p class="text-xs font-medium text-warning">This recreates the container.</p>
        <p class="text-xs text-base-content/60 leading-relaxed">
          The app is briefly unavailable, and its data is left in place. Check the app's own
          upgrade notes first — some (GitLab, Nextcloud, Mastodon) must be upgraded
          one version at a time, and skipping releases can leave the install unrecoverable.
        </p>
      </div>

      <div :if={@editing && match?({:ok, _}, @tags)} class="flex flex-col gap-1.5">
        <span class="text-xs font-medium text-base-content/50">Available versions</span>
        <div class="flex flex-wrap gap-1.5">
          <button
            :for={tag <- elem(@tags, 1)}
            type="button"
            phx-click="settings_select_tag"
            phx-value-tag={tag.tag}
            class={[
              "px-2 py-1 rounded-md text-xs font-mono transition-colors cursor-pointer border",
              if(tagged?(@form.image, tag.tag),
                do: "border-primary bg-primary/10 text-primary",
                else:
                  "border-base-content/10 bg-base-200 text-base-content/70 hover:text-base-content"
              )
            ]}
            title={tag.last_updated && "Updated #{tag.last_updated}"}
          >
            {tag.tag}
          </button>
        </div>
      </div>
      <p :if={@editing && @tags == :loading} class="text-xs text-base-content/40">
        Asking the registry…
      </p>
      <p :if={@editing && match?({:error, _}, @tags)} class="text-xs text-base-content/40">
        The registry did not answer — type a tag above instead.
      </p>

      <div :if={!@editing} class="flex flex-col gap-1">
        <span class="text-xs font-medium text-base-content/50">Running</span>
        <div class="flex items-center gap-2 flex-wrap">
          <span class="font-mono text-sm text-base-content">{@form.image}</span>
          <span
            :if={@form.image != @deployment.app_template.image}
            class="px-1.5 py-0.5 rounded text-[10px] font-medium bg-warning/10 text-warning"
          >
            Pinned
          </span>
          <span
            :if={@form.image == @deployment.app_template.image}
            class="px-1.5 py-0.5 rounded text-[10px] font-medium bg-base-200 text-base-content/50"
          >
            Catalog default
          </span>
        </div>
        <%!-- "What am I diverged from" has to be answerable without opening the editor,
              which is the whole question a pinned image raises. --%>
        <p
          :if={@form.image != @deployment.app_template.image}
          class="text-xs text-base-content/40"
        >
          Catalog default is <span class="font-mono">{@deployment.app_template.image}</span>.
        </p>
      </div>
    </.card>
    """
  end

  # ------------------------------------------------------------------
  # Network
  # ------------------------------------------------------------------

  defp network_card(assigns) do
    assigns = assign(assigns, :allowed, SettingsForm.allowed_exposures(assigns.form))

    ~H"""
    <.card title="Network" subtitle="namespace, ports and routes">
      <div class="flex flex-col gap-1.5 max-w-md">
        <label for="settings-namespace" class="text-xs font-medium text-base-content/50">
          Namespace
        </label>
        <select
          :if={@editing}
          id="settings-namespace"
          name="settings[namespace]"
          class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
        >
          <option value="own" selected={@form.namespace == "own"}>Its own network</option>
          <option value="host" selected={@form.namespace == "host"}>The host's network</option>
          <option
            :if={@netns_candidates != []}
            value="donor"
            selected={@form.namespace == "donor"}
          >
            Through another container
          </option>
        </select>
        <span :if={!@editing} class="text-sm text-base-content">
          {namespace_label(@form, @netns_candidates)}
        </span>
      </div>

      <div :if={@editing && @form.namespace == "donor"} class="flex flex-col gap-1.5 max-w-md">
        <label for="settings-donor" class="text-xs font-medium text-base-content/50">
          Donor container
        </label>
        <select
          id="settings-donor"
          name="settings[donor_id]"
          class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
        >
          <option
            :for={candidate <- @netns_candidates}
            value={to_string(candidate.id)}
            selected={@form.donor_id == to_string(candidate.id)}
          >
            {candidate.app_template.name}
          </option>
        </select>
      </div>

      <.netns_relationship
        donor={@netns_donor}
        children={@netns_children}
        donor_env={@netns_donor_env}
      />

      <.ports_table form={@form} editing={@editing} allowed={@allowed} />

      <.findings list={@findings} />

      <div
        :if={@form.namespace != "host"}
        class="border-t border-base-content/5 pt-4 flex flex-col gap-4"
      >
        <.auth_control form={@form} editing={@editing} />
        <.routes_table form={@form} editing={@editing} deployment={@deployment} />
        <.backend_scheme form={@form} editing={@editing} />
        <.sticky_toggle form={@form} editing={@editing} />
      </div>
    </.card>
    """
  end

  # Both sides of a shared namespace, on the page of whichever container is looking.
  #
  # The derived firewall values are shown because they are COMPUTED rather than typed: a
  # 502 through Traefik is almost always a port missing from this list, and there is
  # nothing in any log that says so.
  defp netns_relationship(assigns) do
    ~H"""
    <div
      :if={@donor || @children != []}
      class="rounded-lg bg-base-200/40 border border-base-content/5 p-3 flex flex-col gap-3"
    >
      <div :if={@donor} class="flex items-center gap-2 text-sm">
        <span class="text-xs font-medium text-base-content/50">Traffic leaves through</span>
        <.link navigate={~p"/deployments/#{@donor.id}"} class="text-primary hover:underline">
          {@donor.app_template.name}
        </.link>
      </div>

      <div :if={@children != []} class="flex flex-col gap-2">
        <h4 class="text-[10px] font-semibold uppercase tracking-wider text-base-content/40">
          Sharing its network
        </h4>
        <ul class="flex flex-col gap-1.5">
          <li
            :for={child <- @children}
            class="flex items-center justify-between gap-3 text-sm"
          >
            <.link navigate={~p"/deployments/#{child.id}"} class="text-primary hover:underline">
              {child.app_template.name}
            </.link>
            <span class="font-mono text-xs text-base-content/50">
              {format_ports(Netns.declared_ports(child))}
            </span>
          </li>
        </ul>
        <dl :if={@donor_env != %{}} class="flex flex-col gap-1.5">
          <div :for={{key, value} <- Enum.sort(@donor_env)}>
            <dt class="text-base-content/50 text-xs">{key}</dt>
            <dd class="font-mono text-xs text-base-content break-all">{value}</dd>
          </div>
        </dl>
      </div>
    </div>
    """
  end

  defp ports_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium text-base-content/50">Ports</span>
        <button
          :if={@editing}
          type="button"
          phx-click="settings_add_port"
          class="text-xs text-primary hover:text-primary/80 cursor-pointer"
        >
          + Add port
        </button>
      </div>

      <p :if={@form.ports == []} class="text-xs text-base-content/50 py-2">
        No ports yet. Add the port the app listens on inside the container.
      </p>

      <div :if={@form.ports != []} class="overflow-x-auto">
        <table class="w-full min-w-[46rem] border-collapse">
          <thead>
            <tr>
              <th class={th_class()}>Port</th>
              <th class={th_class()}>Proto</th>
              <th class={th_class()}>What it's for</th>
              <th class={th_class()}>Exposure</th>
              <th class={th_class()}>Detail</th>
              <th class={th_class()}></th>
            </tr>
          </thead>
          <tbody>
            <%= for {port, idx} <- Enum.with_index(@form.ports) do %>
              <tr class={["border-b border-base-content/5", exposure_edge(port["exposure"])]}>
                <td class="py-1.5 px-2.5">
                  <input
                    :if={@editing}
                    type="text"
                    inputmode="numeric"
                    name={"settings[ports][#{idx}][internal]"}
                    value={port["internal"]}
                    aria-label="Container port"
                    class="w-20 rounded bg-base-200 border-0 text-sm font-mono py-1 px-2"
                  />
                  <span :if={!@editing} class="font-mono text-sm tabular-nums">
                    {port["internal"]}
                  </span>
                </td>
                <td class="py-1.5 px-2.5">
                  <select
                    :if={@editing}
                    name={"settings[ports][#{idx}][protocol]"}
                    aria-label="Protocol"
                    class="w-[4.25rem] rounded bg-base-200 border-0 text-xs font-mono py-1 px-1.5"
                  >
                    <option
                      :for={proto <- ~w(tcp udp)}
                      value={proto}
                      selected={proto == port["protocol"]}
                    >
                      {String.upcase(proto)}
                    </option>
                  </select>
                  <span :if={!@editing} class="font-mono text-xs text-base-content/50">
                    {upcase(port["protocol"])}
                  </span>
                </td>
                <td class="py-1.5 px-2.5">
                  <div class="flex items-center gap-2">
                    <input
                      :if={@editing}
                      type="text"
                      name={"settings[ports][#{idx}][description]"}
                      value={port["description"]}
                      placeholder="what it's for"
                      aria-label="Description"
                      class="flex-1 min-w-0 rounded bg-base-200 border-0 text-xs py-1 px-2"
                    />
                    <span :if={!@editing} class="text-sm text-base-content/70">
                      {blank(port["description"], "—")}
                    </span>
                    <span class="font-mono text-[9px] tracking-wider uppercase text-base-content/40 border border-base-content/10 rounded px-1 py-px">
                      {port["role"]}
                    </span>
                  </div>
                  <input type="hidden" name={"settings[ports][#{idx}][role]"} value={port["role"]} />
                </td>
                <td class="py-1.5 px-2.5">
                  <select
                    :if={@editing && length(@allowed) > 1}
                    name={"settings[ports][#{idx}][exposure]"}
                    aria-label={"Exposure for port #{port["internal"]}"}
                    class={["rounded border-0 text-xs py-1 px-2", exposure_select(port["exposure"])]}
                  >
                    <option
                      :for={value <- ~w(proxy host internal)}
                      value={value}
                      selected={port["exposure"] == value}
                      disabled={value not in @allowed}
                    >
                      {port_exposure_label(value)}
                    </option>
                  </select>
                  <span
                    :if={!@editing || length(@allowed) == 1}
                    class={[
                      "px-2 py-0.5 rounded-full text-[11px] font-medium",
                      exposure_pill_of(port["exposure"])
                    ]}
                  >
                    {port_exposure_label(port["exposure"])}
                  </span>
                  <input
                    :if={@editing && length(@allowed) == 1}
                    type="hidden"
                    name={"settings[ports][#{idx}][exposure]"}
                    value={port["exposure"]}
                  />
                </td>
                <td class="py-1.5 px-2.5">
                  <.port_detail form={@form} port={port} idx={idx} editing={@editing} />
                </td>
                <td class="py-1.5 px-2.5 w-8">
                  <button
                    :if={@editing}
                    type="button"
                    phx-click="settings_remove_port"
                    phx-value-index={idx}
                    aria-label={"Remove port #{port["internal"]}"}
                    class="text-base-content/30 hover:text-error cursor-pointer"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </td>
              </tr>
              <tr :if={SettingsForm.guarded?(@form, port)}>
                <td colspan="6" class="px-2.5 pb-2.5">
                  <.reason severity={:drop} label="Binding dropped">
                    {auth_word(@form)} applies per route, so a host binding on the routed port
                    would answer with nothing in front of it. The binding is dropped on save.
                  </.reason>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  # The right-hand column says what the chosen exposure actually MEANS for this port —
  # the host binding it takes, the hostnames that reach it, or the fact that nothing
  # does. Without it "Proxied" is a word with no consequence attached.
  defp port_detail(%{port: %{"exposure" => "host"}} = assigns) do
    ~H"""
    <span :if={@form.namespace == "host"} class="font-mono text-xs text-base-content/50">
      the host's own port — nothing mapped
    </span>
    <div :if={@form.namespace != "host" && @editing} class="flex items-center gap-1.5">
      <input
        type="text"
        name={"settings[ports][#{@idx}][external]"}
        value={@port["external"]}
        placeholder={@port["internal"]}
        aria-label="Host port"
        class="w-20 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
      />
      <input
        type="text"
        name={"settings[ports][#{@idx}][host_ip]"}
        value={@port["host_ip"]}
        placeholder="all interfaces"
        aria-label="Interface"
        title="Publish on one interface only, e.g. 127.0.0.1. Blank means all interfaces."
        class="w-28 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
      />
    </div>
    <span
      :if={@form.namespace != "host" && !@editing}
      class="font-mono text-xs text-warning"
    >
      {@port["host_ip"] || "0.0.0.0"}:{blank(@port["external"], @port["internal"])}
    </span>
    """
  end

  defp port_detail(%{port: %{"exposure" => "proxy"}} = assigns) do
    assigns =
      assign(
        assigns,
        :hits,
        Enum.filter(
          SettingsForm.live_routes(assigns.form),
          &(to_string(&1["port"]) == to_string(assigns.port["internal"]))
        )
      )

    ~H"""
    <span :if={@hits != []} class="font-mono text-xs text-primary">
      {Enum.map_join(@hits, ", ", &"#{&1["host"]}#{blank(&1["path_prefix"], "/")}")}
    </span>
    <span :if={@hits == []} class="font-mono text-xs text-warning">no route points here yet</span>
    """
  end

  defp port_detail(assigns) do
    ~H"""
    <span :if={@form.namespace == "donor"} class="font-mono text-xs text-base-content/50">
      reachable inside the shared namespace on localhost:{@port["internal"]}
    </span>
    <span :if={@form.namespace != "donor"} class="font-mono text-xs text-base-content/50">
      container network only
    </span>
    """
  end

  defp auth_control(assigns) do
    assigns = assign(assigns, :choices, @auth_choices)

    ~H"""
    <div class="flex items-center gap-3 flex-wrap">
      <span class="text-xs font-medium text-base-content/50">Authentication</span>
      <div :if={@editing} class="inline-flex rounded-lg border border-base-content/10 overflow-hidden">
        <label
          :for={{value, label} <- @choices}
          class={[
            "px-3 py-1 text-xs cursor-pointer border-r border-base-content/10 last:border-r-0",
            if(@form.auth == value,
              do: "bg-primary/10 text-primary font-medium",
              else: "text-base-content/50 hover:text-base-content"
            )
          ]}
        >
          <input
            type="radio"
            name="settings[auth]"
            value={value}
            checked={@form.auth == value}
            class="sr-only"
          />
          {label}
        </label>
      </div>
      <span :if={!@editing} class="text-sm text-base-content">{auth_label(@form.auth)}</span>
      <span class="text-[11px] text-base-content/40">
        {if @form.auth == "public",
          do: "Anyone with the domain.",
          else: "Applied to every route below, including ones you add."}
      </span>
    </div>
    """
  end

  defp routes_table(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium text-base-content/50">Routes</span>
        <button
          :if={@editing}
          type="button"
          phx-click="settings_add_route"
          class="text-xs text-primary hover:text-primary/80 cursor-pointer"
        >
          + Add route
        </button>
      </div>

      <p :if={@form.routes == []} class="text-xs text-base-content/50 py-2 leading-relaxed">
        No routes. Add a hostname to go live — until then the app isn't reachable externally.
        A blank path sends the whole host; rows sharing a host may reach different ports.
      </p>

      <div :if={@form.routes != []} class="overflow-x-auto">
        <table class="w-full min-w-[40rem] border-collapse">
          <thead>
            <tr>
              <th class={th_class()}>Host</th>
              <th class={th_class()}>Path</th>
              <th class={th_class()}>To port</th>
              <th class={th_class()}></th>
              <th class={th_class()}></th>
            </tr>
          </thead>
          <tbody>
            <tr
              :for={{route, idx} <- Enum.with_index(@form.routes)}
              class="border-b border-base-content/5"
            >
              <td class="py-1.5 px-2.5">
                <input
                  :if={@editing}
                  type="text"
                  name={"settings[routes][#{idx}][host]"}
                  value={route["host"]}
                  placeholder={"#{@deployment.app_template.slug}.yourdomain.com"}
                  aria-label="Host"
                  class="w-full rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
                />
                <span :if={!@editing} class="font-mono text-xs">{route["host"]}</span>
              </td>
              <td class="py-1.5 px-2.5">
                <%!-- The primary row IS the whole-host router; Traefik has no way to
                      express a primary that serves only a path, so this cell states the
                      fact rather than offering an input the save would have to ignore. --%>
                <span :if={route["primary"]} class="font-mono text-xs text-base-content/40">
                  / (whole host)
                </span>
                <input
                  :if={@editing && !route["primary"]}
                  type="text"
                  name={"settings[routes][#{idx}][path_prefix]"}
                  value={route["path_prefix"]}
                  placeholder="/.well-known/matrix"
                  aria-label="Path prefix"
                  class="w-full rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
                />
                <span
                  :if={!@editing && !route["primary"]}
                  class="font-mono text-xs text-base-content/50"
                >
                  {blank(route["path_prefix"], "/")}
                </span>
              </td>
              <td class="py-1.5 px-2.5">
                <select
                  :if={@editing && @form.ports != []}
                  name={"settings[routes][#{idx}][port]"}
                  aria-label="Backend port"
                  class="w-24 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
                >
                  <option
                    :for={port <- @form.ports}
                    value={port["internal"]}
                    selected={to_string(route["port"]) == to_string(port["internal"])}
                  >
                    :{port["internal"]}
                  </option>
                </select>
                <input
                  :if={@editing && @form.ports == []}
                  type="text"
                  inputmode="numeric"
                  name={"settings[routes][#{idx}][port]"}
                  value={route["port"]}
                  aria-label="Backend port"
                  class="w-24 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
                />
                <span :if={!@editing} class="font-mono text-xs tabular-nums">:{route["port"]}</span>
              </td>
              <td class="py-1.5 px-2.5 w-24">
                <span
                  :if={route["primary"]}
                  class="px-2 py-0.5 rounded-full text-[11px] font-medium bg-primary/10 text-primary"
                >
                  primary
                </span>
                <span :if={!route["primary"]} class="text-[11px] text-base-content/40">
                  {if same_host?(@form, route), do: "same host", else: "extra host"}
                </span>
              </td>
              <td class="py-1.5 px-2.5 w-8">
                <button
                  :if={@editing}
                  type="button"
                  phx-click="settings_remove_route"
                  phx-value-index={idx}
                  aria-label={"Remove route #{route["host"]}"}
                  class="text-base-content/30 hover:text-error cursor-pointer"
                >
                  <.icon name="hero-x-mark" class="size-4" />
                </button>
              </td>
            </tr>
          </tbody>
        </table>
      </div>
    </div>
    """
  end

  defp backend_scheme(assigns) do
    ~H"""
    <div class="flex flex-col gap-1 max-w-xl">
      <label for="settings-backend-scheme" class="text-xs font-medium text-base-content/50">
        Backend protocol
      </label>
      <select
        :if={@editing}
        id="settings-backend-scheme"
        name="settings[backend_scheme]"
        class="rounded-lg bg-base-200 border-0 text-sm text-base-content py-2 px-3 focus:ring-2 focus:ring-primary/50"
      >
        <option value="http" selected={@form.backend_scheme != "https"}>
          HTTP — the proxy terminates TLS (almost every app)
        </option>
        <option value="https" selected={@form.backend_scheme == "https"}>
          HTTPS — the container serves TLS itself
        </option>
      </select>
      <span :if={!@editing} class="text-sm text-base-content">
        {if @form.backend_scheme == "https",
          do: "HTTPS — the container serves TLS itself",
          else: "HTTP — the proxy terminates TLS"}
      </span>
      <p class="text-[10px] text-base-content/40 leading-snug">
        How Traefik talks to the container, not how browsers reach it — the public side is
        HTTPS either way. An app that terminates TLS itself answers a plaintext request with <span class="font-mono">400 Bad Request</span>.
      </p>
    </div>
    """
  end

  defp sticky_toggle(assigns) do
    ~H"""
    <label class="flex items-start gap-2 cursor-pointer">
      <input type="hidden" name="settings[sticky]" value="false" />
      <input
        type="checkbox"
        name="settings[sticky]"
        value="true"
        checked={@form.sticky}
        disabled={!@editing}
        class="checkbox checkbox-xs checkbox-primary mt-0.5"
      />
      <span class="flex flex-col gap-0.5">
        <span class="text-xs font-medium text-base-content">Sticky sessions</span>
        <span class="text-[10px] text-base-content/40 leading-snug">
          Pins each client to one replica. With more than one container a websocket reconnect
          can otherwise land on a different one and drop the session.
        </span>
      </span>
    </label>
    """
  end

  # ------------------------------------------------------------------
  # Runtime
  # ------------------------------------------------------------------

  defp runtime_card(assigns) do
    assigns = assign(assigns, :policies, @restart_policies)

    ~H"""
    <.card title="Runtime">
      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <div class="flex flex-col gap-1.5">
          <label for="settings-restart" class="text-xs font-medium text-base-content/50">
            Restart policy
          </label>
          <select
            :if={@editing}
            id="settings-restart"
            name="settings[restart_policy]"
            class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3 focus:ring-2 focus:ring-primary/50"
          >
            <option
              :for={{value, label} <- @policies}
              value={value}
              selected={@form.restart_policy == value}
            >
              {label}
            </option>
          </select>
          <span :if={!@editing} class="text-sm text-base-content">
            {policy_label(@form.restart_policy)}
          </span>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="settings-replicas" class="text-xs font-medium text-base-content/50">
            Replicas
          </label>
          <input
            :if={@editing}
            type="number"
            min="1"
            id="settings-replicas"
            name="settings[replicas]"
            value={@form.replicas}
            class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3 focus:ring-2 focus:ring-primary/50"
          />
          <span :if={!@editing} class="text-sm text-base-content">{@form.replicas}</span>
          <p class="text-[10px] text-base-content/40">Scaling past one needs Swarm.</p>
        </div>
      </div>

      <div class="grid grid-cols-1 sm:grid-cols-2 gap-4">
        <.argv_field
          id="settings-command"
          label="Command"
          name="settings[command]"
          value={@form.command}
          catalog={@deployment.app_template.command}
          editing={@editing}
        />
        <.argv_field
          id="settings-entrypoint"
          label="Entrypoint"
          name="settings[entrypoint]"
          value={@form.entrypoint}
          catalog={@deployment.app_template.entrypoint}
          editing={@editing}
        />
      </div>

      <.argv_field
        id="settings-aliases"
        label="Network aliases"
        name="settings[aliases]"
        value={@form.aliases}
        catalog={@deployment.app_template.network_aliases}
        editing={@editing}
        help={
          if @form.namespace == "own",
            do: "Extra names siblings can reach this container by.",
            else: "Refused while sharing a namespace — it has no endpoint to register a name on."
        }
      />

      <.kernel_privileges form={@form} deployment={@deployment} editing={@editing} />
    </.card>
    """
  end

  # One argument per line, and the catalog's own value is what fills the box. A field
  # that renders empty under the word "inherit" hides the one thing the operator opened
  # it to learn; splitting on spaces instead would take `--config /etc/a b.conf` apart.
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :name, :string, required: true
  attr :value, :string, required: true
  attr :catalog, :any, default: nil
  attr :editing, :boolean, required: true
  attr :help, :string, default: nil

  defp argv_field(assigns) do
    ~H"""
    <div class="flex flex-col gap-1.5">
      <label for={@id} class="text-xs font-medium text-base-content/50">{@label}</label>
      <textarea
        :if={@editing}
        id={@id}
        name={@name}
        rows={max(1, length(String.split(@value, "\n")))}
        placeholder="nothing"
        class="w-full rounded-lg bg-base-200 border-0 text-sm font-mono py-2 px-3 focus:ring-2 focus:ring-primary/50 resize-y"
      >{@value}</textarea>
      <span :if={!@editing} class="text-sm font-mono text-base-content whitespace-pre-line">
        {blank(@value, "nothing")}
      </span>
      <p class="text-[10px] text-base-content/40 leading-snug">
        One argument per line — a value with spaces in it stays one argument.
      </p>
      <p :if={@help} class="text-[10px] text-base-content/40 leading-snug">{@help}</p>
      <p
        :if={@editing && catalog_words(@catalog) not in ["", @value]}
        class="text-[10px] text-base-content/40 leading-snug whitespace-pre-line"
      >
        The catalog sets <span class="font-mono">{catalog_words(@catalog)}</span>.
      </p>
    </div>
    """
  end

  # Every capability Docker accepts, with the ones that are on ticked. The field used to
  # be free text behind an "inherit" toggle, which meant the operator could neither see
  # what the container already had nor discover what it could be given without leaving
  # the page — and a typo read exactly like a capability that was never added.
  defp kernel_privileges(assigns) do
    assigns =
      assigns
      |> assign(:capabilities, RuntimeSpec.capabilities())
      |> assign(:count, length(assigns.form.caps_add) + length(assigns.form.caps_drop))

    ~H"""
    <details class="rounded-lg border border-base-content/5 bg-base-200/40" open={@count > 0}>
      <summary class="cursor-pointer px-3 py-2.5 flex items-center gap-2 text-xs font-medium text-base-content/60">
        Kernel privileges
        <span
          :if={@count > 0}
          class="px-2 py-0.5 rounded-full text-[10px] font-medium bg-warning/10 text-warning"
        >
          {@count} set
        </span>
        <span
          :if={@count == 0}
          class="px-2 py-0.5 rounded-full text-[10px] font-medium bg-base-200 text-base-content/50"
        >
          none
        </span>
      </summary>

      <div class="px-3 pb-3 flex flex-col gap-4">
        <p class="text-[11px] text-base-content/50 leading-relaxed">
          What this container may ask the host kernel for. Capabilities marked
          <span class="text-warning font-medium">privileged</span>
          reach past the container — kernel modules, raw I/O, other processes' memory, the
          host clock. NET_ADMIN is exactly what a VPN client legitimately needs.
        </p>

        <.capability_list
          title="Capabilities added"
          name="settings[caps_add][]"
          selected={@form.caps_add}
          capabilities={@capabilities}
          catalog={@deployment.app_template.capabilities_add}
          editing={@editing}
        />

        <.capability_list
          title="Capabilities dropped"
          name="settings[caps_drop][]"
          selected={@form.caps_drop}
          capabilities={["ALL" | @capabilities]}
          catalog={@deployment.app_template.capabilities_drop}
          editing={@editing}
        />

        <.device_rows rows={@form.devices} editing={@editing} />
        <.sysctl_rows rows={@form.sysctls} editing={@editing} />
      </div>
    </details>
    """
  end

  defp capability_list(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-baseline gap-2 flex-wrap">
        <span class="text-xs font-medium text-base-content/50">{@title}</span>
        <span class="text-[10px] text-base-content/40">
          {if @selected == [], do: "none", else: Enum.join(Enum.sort(@selected), ", ")}
        </span>
      </div>

      <%!-- A checkbox group posts nothing at all when every box is cleared, which is
            indistinguishable from the control not being rendered. The sentinel is what
            makes "drop every capability the catalog adds" expressible. --%>
      <input :if={@editing} type="hidden" name={@name} value="" />

      <div :if={@editing} class="flex flex-wrap gap-1">
        <label
          :for={cap <- @capabilities}
          class={[
            "px-2 py-1 rounded-md text-[11px] font-mono border cursor-pointer transition-colors",
            cond do
              cap in @selected && RuntimeSpec.privileged_capability?(cap) ->
                "border-warning bg-warning/10 text-warning"

              cap in @selected ->
                "border-primary bg-primary/10 text-primary"

              true ->
                "border-base-content/10 text-base-content/40 hover:text-base-content/70"
            end
          ]}
          title={
            if RuntimeSpec.privileged_capability?(cap),
              do: "#{cap} — privileged: reaches past the container",
              else: cap
          }
        >
          <input type="checkbox" name={@name} value={cap} checked={cap in @selected} class="sr-only" />
          {cap}
        </label>
      </div>

      <div :if={!@editing} class="flex flex-wrap gap-1">
        <span
          :for={cap <- Enum.sort(@selected)}
          class={[
            "px-2 py-1 rounded-md text-[11px] font-mono border",
            if(RuntimeSpec.privileged_capability?(cap),
              do: "border-warning bg-warning/10 text-warning",
              else: "border-base-content/10 text-base-content/60"
            )
          ]}
        >
          {cap}
        </span>
        <span :if={@selected == []} class="text-[11px] text-base-content/40">none</span>
      </div>

      <p
        :if={@editing && catalog_caps(@catalog) != Enum.sort(@selected)}
        class="text-[10px] text-base-content/40"
      >
        The catalog sets <span class="font-mono">
          {if catalog_caps(@catalog) == [], do: "none", else: Enum.join(catalog_caps(@catalog), ", ")}
        </span>.
      </p>
    </div>
    """
  end

  defp device_rows(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium text-base-content/50">Devices</span>
        <button
          :if={@editing}
          type="button"
          phx-click="settings_add_device"
          class="text-[10px] text-primary hover:underline cursor-pointer"
        >
          + Add device
        </button>
      </div>
      <p :if={@rows == []} class="text-[11px] text-base-content/40">none</p>
      <div :for={{row, idx} <- Enum.with_index(@rows)} class="flex items-center gap-2">
        <input
          :if={@editing}
          type="text"
          name={"settings[devices][#{idx}][host_path]"}
          value={row["host_path"]}
          placeholder="/dev/net/tun"
          aria-label="Host path"
          class="flex-1 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
        />
        <span :if={@editing} class="text-base-content/30 text-xs">→</span>
        <input
          :if={@editing}
          type="text"
          name={"settings[devices][#{idx}][container_path]"}
          value={row["container_path"]}
          placeholder="/dev/net/tun"
          aria-label="Container path"
          class="flex-1 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
        />
        <input
          :if={@editing}
          type="text"
          name={"settings[devices][#{idx}][permissions]"}
          value={row["permissions"]}
          placeholder="rwm"
          aria-label="Permissions"
          class="w-16 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
        />
        <button
          :if={@editing}
          type="button"
          phx-click="settings_remove_device"
          phx-value-index={idx}
          aria-label="Remove device"
          class="text-base-content/30 hover:text-error cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
        <span :if={!@editing} class="font-mono text-xs text-base-content/70">
          {row["host_path"]}:{row["container_path"]}:{row["permissions"]}
        </span>
      </div>
    </div>
    """
  end

  defp sysctl_rows(assigns) do
    ~H"""
    <div class="flex flex-col gap-2">
      <div class="flex items-center justify-between">
        <span class="text-xs font-medium text-base-content/50">Sysctls</span>
        <button
          :if={@editing}
          type="button"
          phx-click="settings_add_sysctl"
          class="text-[10px] text-primary hover:underline cursor-pointer"
        >
          + Add sysctl
        </button>
      </div>
      <p :if={@rows == []} class="text-[11px] text-base-content/40">none</p>
      <div :for={{row, idx} <- Enum.with_index(@rows)} class="flex items-center gap-2">
        <input
          :if={@editing}
          type="text"
          name={"settings[sysctls][#{idx}][key]"}
          value={row["key"]}
          placeholder="net.ipv4.ip_forward"
          aria-label="Sysctl key"
          class="flex-1 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
        />
        <span :if={@editing} class="text-base-content/30 text-xs">=</span>
        <input
          :if={@editing}
          type="text"
          name={"settings[sysctls][#{idx}][value]"}
          value={row["value"]}
          placeholder="1"
          aria-label="Sysctl value"
          class="w-24 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
        />
        <button
          :if={@editing}
          type="button"
          phx-click="settings_remove_sysctl"
          phx-value-index={idx}
          aria-label="Remove sysctl"
          class="text-base-content/30 hover:text-error cursor-pointer"
        >
          <.icon name="hero-x-mark" class="size-3.5" />
        </button>
        <span :if={!@editing} class="font-mono text-xs text-base-content/70">
          {row["key"]}={row["value"]}
        </span>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Resources
  # ------------------------------------------------------------------

  defp resources_card(assigns) do
    assigns =
      assigns
      |> assign(:test, SettingsForm.health_test(assigns.form))
      |> assign(:defaults, SettingsForm.health_defaults())
      |> assign(:probe, SettingsForm.probe_port(assigns.form))

    ~H"""
    <.card title="Resources" subtitle="limits, GPU and readiness">
      <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
        <div class="flex flex-col gap-1.5">
          <label for="settings-memory" class="text-xs font-medium text-base-content/50">
            Memory (MB)
          </label>
          <input
            :if={@editing}
            type="number"
            min="1"
            id="settings-memory"
            name="settings[memory_mb]"
            value={@form.memory_mb}
            placeholder="256"
            class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3"
          />
          <span :if={!@editing} class="text-sm">{blank(@form.memory_mb, "unlimited")}</span>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="settings-cpu" class="text-xs font-medium text-base-content/50">
            CPU shares
          </label>
          <input
            :if={@editing}
            type="number"
            min="1"
            id="settings-cpu"
            name="settings[cpu_shares]"
            value={@form.cpu_shares}
            placeholder="512"
            class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3"
          />
          <span :if={!@editing} class="text-sm">{blank(@form.cpu_shares, "default")}</span>
        </div>
        <div class="flex flex-col gap-1.5">
          <label for="settings-gpu" class="text-xs font-medium text-base-content/50">GPU</label>
          <select
            :if={@editing}
            id="settings-gpu"
            name="settings[gpu_vendor]"
            class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3"
          >
            <option value="" selected={@form.gpu_vendor in [nil, ""]}>None</option>
            <option value="nvidia" selected={@form.gpu_vendor == "nvidia"}>NVIDIA</option>
            <option value="amd" selected={@form.gpu_vendor == "amd"}>AMD (ROCm)</option>
          </select>
          <span :if={!@editing} class="text-sm">{gpu_label(@form.gpu_vendor)}</span>
        </div>
      </div>

      <.gpu_detail
        :if={@form.gpu_vendor in ["nvidia", "amd"]}
        form={@form}
        editing={@editing}
        kinds={@gpu_kinds}
      />

      <div class="border-t border-base-content/5 pt-4 flex flex-col gap-3">
        <.health_editor
          form={@form}
          editing={@editing}
          test={@test}
          probe={@probe}
          defaults={@defaults}
        />
        <.findings list={@findings} />
      </div>

      <div>
        <span
          :if={ready?(@form)}
          class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[11px] font-medium bg-success/10 text-success"
        >
          Resilience gate cleared
        </span>
        <span
          :if={!ready?(@form)}
          class="inline-flex items-center gap-1.5 px-2 py-0.5 rounded-full text-[11px] font-medium bg-warning/10 text-warning"
        >
          Resilience gate open — needs memory, CPU and a declared check
        </span>
      </div>
    </.card>
    """
  end

  defp gpu_detail(assigns) do
    ~H"""
    <div class="grid grid-cols-1 sm:grid-cols-3 gap-4">
      <div class="flex flex-col gap-1.5">
        <label for="settings-gpu-count" class="text-xs font-medium text-base-content/50">
          GPUs to reserve
        </label>
        <input
          type="number"
          min="1"
          id="settings-gpu-count"
          name="settings[gpu_count]"
          value={@form.gpu_count}
          placeholder="1"
          disabled={!@editing}
          class="rounded-lg bg-base-200 border-0 text-sm py-2 px-3"
        />
      </div>
      <div class="flex flex-col gap-1.5">
        <label for="settings-gpu-devices" class="text-xs font-medium text-base-content/50">
          Devices
        </label>
        <input
          type="text"
          id="settings-gpu-devices"
          name="settings[gpu_devices]"
          value={@form.gpu_devices}
          placeholder="all"
          disabled={!@editing}
          class="rounded-lg bg-base-200 border-0 text-sm font-mono py-2 px-3"
        />
      </div>
      <div class="flex flex-col gap-1.5">
        <label for="settings-gpu-kind" class="text-xs font-medium text-base-content/50">
          Swarm resource kind
        </label>
        <input
          type="text"
          id="settings-gpu-kind"
          name="settings[gpu_kind]"
          value={@form.gpu_kind}
          list="gpu-kinds"
          placeholder={GpuSpec.default_kind(@form.gpu_vendor)}
          disabled={!@editing}
          class="rounded-lg bg-base-200 border-0 text-sm font-mono py-2 px-3"
        />
        <datalist id="gpu-kinds">
          <option :for={kind <- @kinds} value={kind}></option>
        </datalist>
      </div>
    </div>

    <.reason severity={:note} label="Swarm cannot pass a device">
      A GPU is reachable only as a generic resource the node declares in its
      <code class="font-mono">daemon.json</code>
      — the reservation decides which node the task lands on, and that node's default
      runtime is what puts the device in the container.
      <span :if={@kinds == []} class="text-warning">
        No node in this swarm currently advertises a GPU, so deploying this would leave the
        task pending forever.
      </span>
      <span :if={@kinds != []}>Nodes advertise: {Enum.join(@kinds, ", ")}.</span>
    </.reason>
    """
  end

  # Three kinds of check, and the Docker `Test` array each one emits. The page used to
  # offer a single "health check path" field and read nothing else, so a container
  # adopted with a command check displayed as having none — and saving the page replaced
  # its real check with an HTTP probe against a port it does not serve.
  defp health_editor(assigns) do
    ~H"""
    <div class="flex flex-col gap-3">
      <div class="flex items-center gap-3 flex-wrap">
        <span class="text-xs font-medium text-base-content/50">Health check</span>
        <div
          :if={@editing}
          class="inline-flex rounded-lg border border-base-content/10 overflow-hidden"
        >
          <label
            :for={{value, label} <- [{"path", "HTTP path"}, {"command", "Command"}, {"none", "None"}]}
            class={[
              "px-3 py-1 text-xs cursor-pointer border-r border-base-content/10 last:border-r-0",
              if(@form.health["mode"] == value,
                do: "bg-primary/10 text-primary font-medium",
                else: "text-base-content/50 hover:text-base-content"
              )
            ]}
          >
            <input
              type="radio"
              name="settings[health][mode]"
              value={value}
              checked={@form.health["mode"] == value}
              class="sr-only"
            />
            {label}
          </label>
        </div>
      </div>

      <div :if={@form.health["mode"] == "path"} class="flex flex-col gap-1.5 max-w-xl">
        <label for="settings-health-path" class="text-[10px] text-base-content/40">Path</label>
        <input
          :if={@editing}
          type="text"
          id="settings-health-path"
          name="settings[health][path]"
          value={@form.health["path"]}
          placeholder="/health"
          class="rounded-lg bg-base-200 border-0 text-sm font-mono py-2 px-3"
        />
        <span :if={!@editing} class="text-sm font-mono">{blank(@form.health["path"], "—")}</span>
        <p class="text-[10px] text-base-content/40">
          Probed as
          <span class="font-mono">
            {@form.backend_scheme}://localhost:{elem(@probe, 0)}{blank(@form.health["path"], "/…")}
          </span>
          {probe_source(elem(@probe, 1))}
        </p>
      </div>

      <div :if={@form.health["mode"] == "command"} class="flex flex-col gap-3">
        <div class="flex items-center gap-3 flex-wrap">
          <span class="text-[10px] text-base-content/40">Form</span>
          <div
            :if={@editing}
            class="inline-flex rounded-lg border border-base-content/10 overflow-hidden"
          >
            <label
              :for={{value, label} <- [{"true", "Shell"}, {"false", "Exec"}]}
              class={[
                "px-3 py-1 text-xs cursor-pointer border-r border-base-content/10 last:border-r-0",
                if(to_string(@form.health["shell"]) == value,
                  do: "bg-primary/10 text-primary font-medium",
                  else: "text-base-content/50 hover:text-base-content"
                )
              ]}
            >
              <input
                type="radio"
                name="settings[health][shell]"
                value={value}
                checked={to_string(@form.health["shell"]) == value}
                class="sr-only"
              />
              {label}
            </label>
          </div>
          <span class="text-[10px] text-base-content/40">
            {if @form.health["shell"],
              do: "Run through /bin/sh -c.",
              else: "Argv straight to exec — no shell, no word splitting."}
          </span>
        </div>

        <div :if={@form.health["shell"]} class="flex flex-col gap-1.5">
          <input
            :if={@editing}
            type="text"
            name="settings[health][command]"
            value={@form.health["command"]}
            placeholder="curl -fsS http://localhost:8080/up"
            aria-label="Health check command"
            class="rounded-lg bg-base-200 border-0 text-sm font-mono py-2 px-3"
          />
          <span :if={!@editing} class="text-sm font-mono">{blank(@form.health["command"], "—")}</span>
          <p class="text-[10px] text-base-content/40">A non-zero exit is unhealthy.</p>
        </div>

        <div :if={!@form.health["shell"]} class="flex flex-col gap-1.5">
          <span class="text-[10px] text-base-content/40">Arguments</span>
          <div
            :for={{arg, idx} <- Enum.with_index(@form.health["args"])}
            class="flex items-center gap-2"
          >
            <span class="font-mono text-[10px] text-base-content/40 w-4 text-right">{idx}</span>
            <input
              :if={@editing}
              type="text"
              name={"settings[health][args][#{idx}]"}
              value={arg}
              placeholder={if idx == 0, do: "/usr/bin/healthcheck", else: "argument"}
              aria-label={"Argument #{idx}"}
              class="flex-1 rounded bg-base-200 border-0 text-xs font-mono py-1 px-2"
            />
            <span :if={!@editing} class="font-mono text-xs">{arg}</span>
            <button
              :if={@editing && length(@form.health["args"]) > 1}
              type="button"
              phx-click="settings_remove_health_arg"
              phx-value-index={idx}
              aria-label={"Remove argument #{idx}"}
              class="text-base-content/30 hover:text-error cursor-pointer"
            >
              <.icon name="hero-x-mark" class="size-3.5" />
            </button>
          </div>
          <button
            :if={@editing}
            type="button"
            phx-click="settings_add_health_arg"
            class="self-start text-[10px] text-primary hover:underline cursor-pointer"
          >
            + Add argument
          </button>
        </div>
      </div>

      <.reason :if={@form.health["mode"] == "none"} severity={:note} label="No check declared">
        Readiness falls back to a running-and-stable window. The gate stays open.
      </.reason>

      <%!-- The array the daemon is actually handed. Everything above is a way of
            writing it, and showing it is what keeps the three modes from being three
            unrelated features. --%>
      <div class="rounded bg-base-200 px-3 py-2 overflow-x-auto">
        <span class="font-mono text-[11px] text-base-content/60">
          <%= if @test do %>
            Emits <span class="text-base-content">{inspect(@test)}</span>
          <% else %>
            Emits <span class="text-base-content">no Healthcheck</span>
            — readiness falls back to running-and-stable.
          <% end %>
        </span>
      </div>

      <div :if={@form.health["mode"] != "none"} class="grid grid-cols-2 sm:grid-cols-4 gap-3">
        <div :for={{field, label} <- health_timing_fields()} class="flex flex-col gap-1">
          <label for={"settings-health-#{field}"} class="text-[10px] text-base-content/40">
            {label}
          </label>
          <input
            :if={@editing}
            type="number"
            min="1"
            id={"settings-health-#{field}"}
            name={"settings[health][#{field}]"}
            value={@form.health[field]}
            placeholder={to_string(@defaults[field])}
            class="rounded bg-base-200 border-0 text-sm py-1.5 px-2"
          />
          <span :if={!@editing} class="text-sm">
            {blank(@form.health[field], to_string(@defaults[field]))}
          </span>
        </div>
      </div>
      <p :if={@form.health["mode"] != "none"} class="text-[10px] text-base-content/40">
        Blank uses the default. Start period is grace before a failure counts.
      </p>
    </div>
    """
  end

  defp health_timing_fields do
    [
      {"interval", "Interval (s)"},
      {"timeout", "Timeout (s)"},
      {"retries", "Retries"},
      {"start_period", "Start period (s)"}
    ]
  end

  # ------------------------------------------------------------------
  # Save bar and review sheet
  # ------------------------------------------------------------------

  defp save_bar(assigns) do
    ~H"""
    <div
      :if={@diff != []}
      class="sticky bottom-0 z-30 -mx-4 px-4 py-3 bg-base-100/95 backdrop-blur border-t border-base-content/10 flex items-center justify-between gap-4 flex-wrap"
    >
      <span class="flex items-center gap-2.5 flex-wrap text-sm text-base-content/60">
        <b class="font-semibold text-base-content">
          {length(@diff)} {if length(@diff) == 1, do: "change", else: "changes"}
        </b>
        <span class="px-2 py-0.5 rounded-full text-[11px] font-medium bg-warning/10 text-warning">
          recreates the container
        </span>
        <span class="text-xs text-base-content/40">
          The app restarts briefly. Volumes are untouched.
        </span>
      </span>
      <span class="flex gap-2">
        <button
          type="button"
          phx-click="settings_discard"
          class="px-3 py-1.5 rounded-lg text-sm text-base-content/70 hover:bg-base-200 cursor-pointer"
        >
          Discard
        </button>
        <button
          type="button"
          phx-click="settings_review"
          class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
        >
          Review &amp; recreate
        </button>
      </span>
    </div>
    """
  end

  defp review_sheet(assigns) do
    ~H"""
    <%!-- The backdrop carries no phx-click of its own: a click anywhere inside the sheet
          bubbles to it, so a backdrop handler would close the sheet on the way to
          "Recreate now" and on every attempt to select text. phx-click-away on the
          dialog is the click-outside handler, and it does not fire for its own
          children. --%>
    <div
      class="fixed inset-0 z-[80] bg-black/60 backdrop-blur-sm flex items-center justify-center p-6"
      phx-window-keydown="settings_close_review"
      phx-key="escape"
    >
      <div
        class="bg-base-100 border border-base-content/10 rounded-xl w-full max-w-2xl max-h-[80vh] flex flex-col overflow-hidden shadow-2xl"
        role="dialog"
        aria-modal="true"
        aria-labelledby="settings-review-title"
        phx-click-away="settings_close_review"
      >
        <header class="px-5 py-4 border-b border-base-content/5">
          <h3 id="settings-review-title" class="text-base font-semibold text-base-content">
            Recreate {@deployment.app_template.name}?
          </h3>
          <p class="text-xs text-base-content/50 mt-1">
            The container stops and starts again with this configuration. Data in volumes is
            left in place.
          </p>
        </header>

        <div class="px-5 py-3 overflow-y-auto flex flex-col">
          <div
            :for={row <- @rows}
            class="grid grid-cols-[9.5rem_minmax(0,1fr)] gap-3 py-2 border-b border-base-content/5 last:border-b-0 text-xs"
          >
            <span class="text-base-content/50">{row.label}</span>
            <span class="font-mono text-xs break-words">
              <span class="text-base-content/40 line-through">{blank(row.was, "—")}</span>
              <span class="text-base-content/40 px-1.5">→</span>
              <span class="text-base-content">{blank(row.now, "—")}</span>
            </span>
          </div>
        </div>

        <footer class="px-5 py-3 border-t border-base-content/5 flex justify-end gap-2">
          <button
            type="button"
            phx-click="settings_close_review"
            class="px-3 py-1.5 rounded-lg text-sm text-base-content/70 hover:bg-base-200 cursor-pointer"
          >
            Cancel
          </button>
          <button
            type="button"
            phx-click="save_settings"
            class="px-4 py-2 rounded-lg bg-primary text-primary-content text-sm font-medium cursor-pointer"
          >
            Recreate now
          </button>
        </footer>
      </div>
    </div>
    """
  end

  # ------------------------------------------------------------------
  # Shared bits
  # ------------------------------------------------------------------

  slot :inner_block, required: true
  attr :title, :string, required: true
  attr :subtitle, :string, default: nil

  defp card(assigns) do
    ~H"""
    <div class="rounded-lg bg-base-100 border border-base-content/5 overflow-hidden">
      <div class="flex items-center gap-2 px-4 py-3 border-b border-base-content/5">
        <h3 class="text-sm font-semibold text-base-content">{@title}</h3>
        <span :if={@subtitle} class="text-[11px] text-base-content/40">{@subtitle}</span>
      </div>
      <div class="p-4 flex flex-col gap-4">{render_slot(@inner_block)}</div>
    </div>
    """
  end

  attr :list, :list, required: true

  defp findings(assigns) do
    ~H"""
    <div :if={@list != []} class="flex flex-col gap-2">
      <.reason :for={finding <- @list} severity={finding.severity} label={finding.key}>
        {finding.text}
      </.reason>
    </div>
    """
  end

  slot :inner_block, required: true
  attr :severity, :atom, required: true
  attr :label, :string, required: true

  # A severity is a promise about what the save will do, so it gets its own colour: an
  # operator who cannot tell a refusal from a note has to read all four.
  defp reason(assigns) do
    ~H"""
    <div class={["flex gap-2.5 items-start rounded px-3 py-2.5 border-l-2", severity_class(@severity)]}>
      <span class="text-[10px] font-semibold tracking-wider uppercase whitespace-nowrap pt-px">
        {@label}
      </span>
      <span class="text-[11px] leading-relaxed">{render_slot(@inner_block)}</span>
    </div>
    """
  end

  defp severity_class(:refuse), do: "bg-error/10 border-error text-base-content/80"
  defp severity_class(:drop), do: "bg-warning/10 border-warning text-base-content/80"
  defp severity_class(:broken), do: "bg-warning/10 border-warning text-base-content/80"
  defp severity_class(_note), do: "bg-base-200 border-base-content/20 text-base-content/60"

  defp th_class,
    do:
      "text-left text-[10px] font-semibold tracking-wider uppercase text-base-content/40 " <>
        "pb-2 px-2.5 border-b border-base-content/5 whitespace-nowrap"

  defp exposure_edge("proxy"), do: "shadow-[inset_2px_0_0_var(--color-primary)]"
  defp exposure_edge("host"), do: "shadow-[inset_2px_0_0_var(--color-warning)]"
  defp exposure_edge(_internal), do: ""

  defp exposure_select("proxy"), do: "bg-primary/10 text-primary"
  defp exposure_select("host"), do: "bg-warning/10 text-warning"
  defp exposure_select(_internal), do: "bg-base-200 text-base-content/60"

  defp port_exposure_label("proxy"), do: "Proxied"
  defp port_exposure_label("host"), do: "Published on host"
  defp port_exposure_label(_internal), do: "Internal"

  defp exposure_pill_of("proxy"), do: "bg-primary/10 text-primary"
  defp exposure_pill_of("host"), do: "bg-warning/10 text-warning"
  defp exposure_pill_of(_internal), do: "bg-base-200 text-base-content/50"

  defp exposure_pill("host_network"), do: "bg-base-200 text-base-content/60"
  defp exposure_pill("host"), do: "bg-warning/10 text-warning"
  defp exposure_pill("service"), do: "bg-base-200 text-base-content/60"
  defp exposure_pill(_proxy), do: "bg-primary/10 text-primary"

  defp exposure_label("host_network"), do: "Host network"
  defp exposure_label("host"), do: "Host ports"
  defp exposure_label("service"), do: "Internal only"
  defp exposure_label("sso_protected"), do: "Reverse proxy · SSO"
  defp exposure_label("private"), do: "Reverse proxy · LAN only"
  defp exposure_label(_public), do: "Reverse proxy"

  defp auth_label("sso_protected"), do: "SSO — requires login"
  defp auth_label("private"), do: "Private — LAN / IP allowlist"
  defp auth_label(_public), do: "None — anyone with the domain"

  defp auth_word(%{auth: "private"}), do: "The IP allowlist"
  defp auth_word(_form), do: "SSO"

  defp namespace_label(%{namespace: "own"}, _candidates), do: "Its own network"
  defp namespace_label(%{namespace: "host"}, _candidates), do: "The host's network"

  defp namespace_label(%{donor_id: id}, candidates),
    do: "Through #{donor_name(candidates, id)}"

  defp donor_name(candidates, id) do
    case Enum.find(candidates, &(to_string(&1.id) == to_string(id))) do
      nil -> "another container"
      candidate -> candidate.app_template.name
    end
  end

  defp policy_label(value) do
    case List.keyfind(@restart_policies, value, 0) do
      {_value, label} -> label
      nil -> to_string(value)
    end
  end

  defp gpu_label("nvidia"), do: "NVIDIA"
  defp gpu_label("amd"), do: "AMD (ROCm)"
  defp gpu_label(_none), do: "None"

  defp probe_source(:route), do: "— the port the proxy forwards to."
  defp probe_source(:guess), do: "— inferred; no route names a port."
  defp probe_source(:fallback), do: "— no TCP port declared, fell back to 80."

  defp ready?(form) do
    present?(form.memory_mb) and present?(form.cpu_shares) and SettingsForm.declares_health?(form)
  end

  defp same_host?(form, route) do
    case SettingsForm.live_routes(form) do
      [primary | _rest] -> primary["host"] == route["host"]
      [] -> false
    end
  end

  defp tagged?(image, tag), do: String.ends_with?(to_string(image), ":#{tag}")

  defp catalog_words(nil), do: ""
  defp catalog_words(words) when is_list(words), do: Enum.join(words, "\n")
  defp catalog_words(value), do: to_string(value)

  defp catalog_caps(caps), do: caps |> RuntimeSpec.parse_capabilities() |> Enum.sort()

  defp format_ports([]), do: "no known ports"
  defp format_ports(ports), do: Enum.map_join(ports, ", ", &to_string/1)

  defp upcase(value), do: value |> to_string() |> String.upcase()

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(_value), do: false

  defp blank(value, fallback) do
    if present?(to_string(value || "")), do: value, else: fallback
  end
end
