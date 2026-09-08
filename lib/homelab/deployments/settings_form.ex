defmodule Homelab.Deployments.SettingsForm do
  @moduledoc """
  The whole editable configuration of a deployment, as one struct.

  The Settings tab used to hold thirty-odd assigns across three independent forms
  (version, runtime, network) that saved separately. That shape is why the page could
  not answer "what am I about to change?" — there was no single before-and-after to
  compare, so each form asked for its own confirmation and none of them could show the
  operator the whole edit.

  This module is that single before-and-after. `from_deployment/1` reads one, params
  round-trip through `from_params/2`, `diff/2` compares two, and `to_attrs/2` turns one
  back into deployment attrs. The LiveView holds two of these — the pristine one and
  the edited one — and everything the page shows is derived from the pair.

  ## Namespace and exposure are separate questions

  `exposure_mode` conflated them. "Host network" sat in the same radio group as
  "Reverse proxy", so choosing where the container's network *comes from* and choosing
  how each port is *reached* were one control — and since a container has one namespace
  but many ports, the single control could not describe a git server that proxies its
  web UI and publishes SSH.

  Here `namespace` answers the first question (`"own"` / `"host"` / `"donor"`) and each
  port carries its own `"exposure"` (`"proxy"` / `"host"` / `"internal"`). `exposure/1`
  derives the stored `exposure_mode` from the two, so nothing downstream changes.
  """

  alias Homelab.Catalog.Enrichers.PortRoles
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.GpuSpec
  alias Homelab.Deployments.RuntimeSpec
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.IndexedParams
  alias Homelab.Networking.Hostname

  @health_defaults %{"interval" => 30, "timeout" => 10, "retries" => 3, "start_period" => 10}

  defstruct image: "",
            namespace: "own",
            donor_id: "",
            donor_kind: nil,
            auth: "public",
            sticky: false,
            backend_scheme: "http",
            restart_policy: "on-failure",
            replicas: "1",
            command: "",
            entrypoint: "",
            aliases: "",
            caps_add: [],
            caps_drop: [],
            devices: [],
            sysctls: [],
            memory_mb: "",
            cpu_shares: "",
            gpu_vendor: "",
            gpu_count: "",
            gpu_devices: "",
            gpu_kind: "",
            health: %{},
            ports: [],
            routes: []

  @type t :: %__MODULE__{}

  # ------------------------------------------------------------------
  # Reading a deployment
  # ------------------------------------------------------------------

  @doc "Reads a deployment into the form state the editor renders."
  def from_deployment(%Deployment{} = deployment) do
    ports = editable_ports(deployment)
    limits = Access.effective_resource_limits(deployment)
    gpu = GpuSpec.parse(limits) || %{}

    %__MODULE__{
      image: Access.effective_image(deployment),
      namespace: namespace_of(deployment),
      donor_id: deployment.network_parent_id && to_string(deployment.network_parent_id),
      # Whether THIS deployment is the kind of container others route through. Carried so
      # the findings pass can tell a VPN client being given a hostname of its own from an
      # ordinary app being given one.
      donor_kind: deployment.app_template.netns_donor_kind,
      auth: Access.auth_of(Access.effective_exposure(deployment)),
      sticky: (deployment.proxy_options || %{})["sticky"] == true,
      backend_scheme: SpecBuilder.backend_scheme(deployment),
      restart_policy: Access.effective_restart_policy(deployment),
      replicas: to_string(Access.effective_replicas(deployment)),
      memory_mb: to_string(limits["memory_mb"] || ""),
      cpu_shares: to_string(limits["cpu_shares"] || ""),
      gpu_vendor: Map.get(gpu, :vendor, ""),
      gpu_count: to_string(Map.get(gpu, :count, "")),
      gpu_devices: Map.get(gpu, :devices, ""),
      gpu_kind: Map.get(gpu, :kind, ""),
      health: read_health(Access.effective_health_check(deployment)),
      ports: ports,
      routes: read_routes(deployment),
      command: join_words(Access.effective_command(deployment)),
      entrypoint: join_words(Access.effective_entrypoint(deployment)),
      aliases: join_words(Access.effective_network_aliases(deployment)),
      caps_add: Access.effective_capabilities_add(deployment),
      caps_drop: Access.effective_capabilities_drop(deployment),
      devices: RuntimeSpec.parse_device_rows(Access.effective_devices(deployment)),
      sysctls: sysctl_rows_of(Access.effective_sysctls(deployment))
    }
  end

  defp namespace_of(%Deployment{network_parent_id: id}) when not is_nil(id), do: "donor"

  defp namespace_of(deployment) do
    if Access.host_network_mode?(deployment), do: "host", else: "own"
  end

  # A port's exposure is not stored; it is read back from the two things that are.
  # `published` is the host binding, and being the backend of any route is what makes a
  # port proxied — so a port the proxy forwards to reads as "Proxied" whether that
  # decision was made through `routed_port`, an extra path route or an alias host.
  defp editable_ports(deployment) do
    routed = routed_ports(deployment)
    host_ns? = Access.host_network_mode?(deployment)

    deployment
    |> Access.effective_ports()
    |> Enum.map(fn p ->
      internal = to_string(p["internal"] || p["container_port"] || "")

      exposure =
        cond do
          host_ns? -> "host"
          p["published"] == true -> "host"
          MapSet.member?(routed, internal) -> "proxy"
          true -> "internal"
        end

      %{
        "internal" => internal,
        "external" => to_string(p["external"] || p["host_port"] || ""),
        "role" => p["role"] || "other",
        "protocol" => Access.port_protocol(p),
        # nil renders blank, which means "all interfaces" here, in the stored map and
        # to Docker alike.
        "host_ip" => p["host_ip"],
        "description" => p["description"] || "",
        "optional" => p["optional"] == true,
        "exposure" => exposure
      }
    end)
  end

  # Every port any route names, through the same `routed_port/1` the spec builder uses
  # so the table cannot show an exposure the deployment does not have.
  defp routed_ports(deployment) do
    if Access.proxy_mode?(deployment) and present?(deployment.domain) do
      primary = SpecBuilder.routed_port(deployment)

      extras =
        Enum.map(List.wrap(deployment.extra_routes), &to_string(&1["port"] || primary))

      aliases =
        Enum.map(List.wrap(deployment.additional_domains), &to_string(&1["port"] || primary))

      MapSet.new([primary | extras ++ aliases])
    else
      MapSet.new()
    end
  end

  # The primary domain, the extra path routes and the alias hosts are one table: every
  # one of them is `host + path -> port`. Only their storage differs.
  defp read_routes(deployment) do
    if Access.proxy_mode?(deployment) and present?(deployment.domain) do
      primary_port = SpecBuilder.routed_port(deployment)

      primary = %{
        "host" => deployment.domain,
        "path_prefix" => "",
        "port" => primary_port,
        "primary" => true
      }

      extras =
        for route <- List.wrap(deployment.extra_routes) do
          %{
            "host" => deployment.domain,
            "path_prefix" => route["path_prefix"] || "",
            "port" => to_string(route["port"] || primary_port),
            "primary" => false
          }
        end

      aliases =
        for domain <- List.wrap(deployment.additional_domains) do
          %{
            "host" => domain["host"] || "",
            "path_prefix" => domain["path_prefix"] || "",
            "port" => to_string(domain["port"] || primary_port),
            "primary" => false
          }
        end

      [primary | extras ++ aliases]
    else
      []
    end
  end

  # ------------------------------------------------------------------
  # Round-tripping the form
  # ------------------------------------------------------------------

  @doc """
  Rebuilds the form from what the browser posted, falling back to the current value for
  anything the params did not carry.

  Every field round-trips, including the ones a save could read straight from the
  params. A control whose value is recomputed from the deployment on each render
  reverts under the operator's cursor as soon as they touch a different field, and the
  save then writes the value they thought they had replaced.
  """
  def from_params(%__MODULE__{} = form, params) when is_map(params) do
    %{
      form
      | image: carry(params["image"], form.image),
        namespace: carry(params["namespace"], form.namespace),
        donor_id: carry(params["donor_id"], form.donor_id),
        auth: carry(params["auth"], form.auth),
        sticky: carry_flag(params["sticky"], form.sticky),
        backend_scheme: carry(params["backend_scheme"], form.backend_scheme),
        restart_policy: carry(params["restart_policy"], form.restart_policy),
        replicas: carry(params["replicas"], form.replicas),
        command: carry(params["command"], form.command),
        entrypoint: carry(params["entrypoint"], form.entrypoint),
        aliases: carry(params["aliases"], form.aliases),
        caps_add: carry_caps(params["caps_add"], form.caps_add),
        caps_drop: carry_caps(params["caps_drop"], form.caps_drop),
        devices: carry_rows(params["devices"], form.devices, &RuntimeSpec.parse_device_rows/1),
        sysctls: carry_rows(params["sysctls"], form.sysctls, &sysctl_rows/1),
        memory_mb: carry(params["memory_mb"], form.memory_mb),
        cpu_shares: carry(params["cpu_shares"], form.cpu_shares),
        gpu_vendor: carry(params["gpu_vendor"], form.gpu_vendor),
        gpu_count: carry(params["gpu_count"], form.gpu_count),
        gpu_devices: carry(params["gpu_devices"], form.gpu_devices),
        gpu_kind: carry(params["gpu_kind"], form.gpu_kind),
        health: carry_health(params["health"], form.health),
        ports: carry_rows(params["ports"], form.ports, &port_rows/1),
        routes: carry_rows(params["routes"], form.routes, &route_rows/1)
    }
    |> normalize()
  end

  def from_params(%__MODULE__{} = form, _params), do: form

  # `""` is a real answer everywhere here — a cleared image field, "its own network" for
  # the donor id — so only a key the form did not post at all falls back.
  defp carry(nil, current), do: current
  defp carry(value, _current), do: value

  # The checkbox always posts, because a hidden "false" rides in front of it. A payload
  # that carries no key at all is a partial post, and must not read as "unticked".
  defp carry_flag(nil, current), do: current
  defp carry_flag(value, _current), do: value == "true"

  defp carry_rows(nil, current, _parse), do: current
  defp carry_rows(params, _current, parse), do: parse.(params)

  defp port_rows(params) when is_map(params) do
    params
    |> indexed()
    |> Enum.map(fn p ->
      %{
        "internal" => p["internal"] || "",
        "external" => p["external"] || "",
        "role" => role_for(p),
        "protocol" => Access.port_protocol(p),
        "host_ip" => p["host_ip"],
        "description" => p["description"] || "",
        "optional" => p["optional"] == "true",
        "exposure" => p["exposure"] || "internal"
      }
    end)
  end

  defp port_rows(_params), do: []

  # Infer only when the form carried no role at all. "other" is an explicit answer, and
  # re-inferring it would keep promoting a deliberately demoted port back to "web" —
  # which is the role the proxy routes to.
  defp role_for(%{"role" => role}) when role not in [nil, ""], do: role
  defp role_for(%{"internal" => internal}), do: PortRoles.infer(internal)
  defp role_for(_port), do: "other"

  defp route_rows(params) when is_map(params) do
    params
    |> indexed()
    |> Enum.with_index()
    |> Enum.map(fn {r, idx} ->
      %{
        "host" => r["host"] || "",
        "path_prefix" => r["path_prefix"] || "",
        "port" => r["port"] || "",
        "primary" => idx == 0
      }
    end)
  end

  defp route_rows(_params), do: []

  defp sysctl_rows(params) do
    params
    |> indexed()
    |> Enum.map(&%{"key" => &1["key"] || "", "value" => &1["value"] || ""})
  end

  defp indexed(params), do: IndexedParams.ordered(params)

  defp carry_health(nil, current), do: current

  defp carry_health(params, current) do
    %{
      "mode" => params["mode"] || current["mode"],
      "path" => params["path"] || current["path"],
      "shell" => shell_flag(params["shell"], current["shell"]),
      "command" => params["command"] || current["command"],
      "args" => carry_rows(params["args"], current["args"], &arg_rows/1),
      "interval" => params["interval"] || current["interval"],
      "timeout" => params["timeout"] || current["timeout"],
      "retries" => params["retries"] || current["retries"],
      "start_period" => params["start_period"] || current["start_period"]
    }
  end

  defp shell_flag(nil, current), do: current
  defp shell_flag("true", _current), do: true
  defp shell_flag(_value, _current), do: false

  defp arg_rows(params) do
    params
    |> indexed()
    |> Enum.map(fn
      arg when is_binary(arg) -> arg
      %{"value" => value} -> value || ""
      _row -> ""
    end)
  end

  # ------------------------------------------------------------------
  # Normalization — the rules the daemon and the schema already enforce
  # ------------------------------------------------------------------

  @doc """
  Settles the form against the rules it cannot break, so the page never renders a
  configuration the save would refuse.

  Applied after every change rather than at save: a namespace that forbids an exposure
  has to take that exposure off the port the moment it is chosen, or the operator reads
  a table describing a deployment they cannot have.
  """
  def normalize(%__MODULE__{} = form) do
    allowed = allowed_exposures(form)

    ports =
      Enum.map(form.ports, fn port ->
        if port["exposure"] in allowed,
          do: port,
          else: Map.put(port, "exposure", List.first(allowed))
      end)

    # A container in the host's namespace has no address on any bridge, so Traefik has
    # no backend to route to. There is no configuration where the two coexist.
    routes = if form.namespace == "host", do: [], else: reindex_primary(form.routes)

    %{form | ports: ports, routes: routes, donor_id: donor_id_for(form)}
  end

  defp donor_id_for(%{namespace: "donor", donor_id: id}), do: id
  defp donor_id_for(_form), do: ""

  # Exactly one row is primary — the first. It is the row that becomes `domain`, and
  # removing it has to promote the next rather than leave the table with none.
  defp reindex_primary(routes) do
    Enum.with_index(routes, fn route, idx -> Map.put(route, "primary", idx == 0) end)
  end

  @doc """
  The exposures a port may take, given where the container's network comes from.

  In the host's namespace every listening port is already a host port, and there is
  nothing to map or proxy. Inside another container's namespace the daemon refuses port
  bindings outright, so `"host"` is unreachable — the proxy still works, because the
  route is served from the donor's address.
  """
  def allowed_exposures(%__MODULE__{namespace: "host"}), do: ["host"]
  def allowed_exposures(%__MODULE__{namespace: "donor"}), do: ["proxy", "internal"]
  def allowed_exposures(%__MODULE__{}), do: ["proxy", "host", "internal"]

  @doc """
  The `exposure_mode` this configuration stores.

  Derived rather than chosen. It is still the value everything downstream reads, but
  asking the operator for it directly is what forced the namespace and the per-port
  question into one control.
  """
  def exposure(%__MODULE__{namespace: "host"}), do: "host_network"

  def exposure(%__MODULE__{} = form) do
    cond do
      routes?(form) -> form.auth
      Enum.any?(form.ports, &(&1["exposure"] == "host")) -> "host"
      true -> "service"
    end
  end

  defp routes?(form), do: Enum.any?(form.routes, &present?(&1["host"]))

  @doc "The route rows that name a host, primary first."
  def live_routes(%__MODULE__{} = form), do: Enum.filter(form.routes, &present?(&1["host"]))

  @doc "True when any route forwards to this port."
  def routed?(%__MODULE__{} = form, port) do
    Enum.any?(form.routes, &(to_string(&1["port"]) == to_string(port)))
  end

  @doc "The auth in front of every route: `nil` when there is none."
  def protected?(%__MODULE__{auth: auth}), do: auth in ~w(sso_protected private)

  @doc """
  A host binding the save will drop.

  Traefik applies auth per router, so a host binding on a port it forwards to answers
  with nothing in front of it. `SpecBuilder.build_ports/1` refuses these regardless of
  what the form says; stating the same rule here means the operator is told before the
  save rather than finding the binding gone afterwards.
  """
  def guarded?(%__MODULE__{} = form, port) do
    protected?(form) and port["exposure"] == "host" and routed?(form, port["internal"])
  end

  # ------------------------------------------------------------------
  # Health check
  # ------------------------------------------------------------------

  @doc "Default interval, timeout, retries and start period, as the daemon applies them."
  def health_defaults, do: @health_defaults

  # Reads a stored healthcheck into the editor's four modes. `test` is the raw Docker
  # array, so it round-trips whichever form it was captured in — adoption reads one off
  # the original container and an exec-form check must not come back as a shell string.
  defp read_health(hc) do
    hc = hc || %{}

    base = %{
      "path" => "",
      "shell" => true,
      "command" => "",
      "args" => [""],
      "interval" => to_string(hc["interval"] || ""),
      "timeout" => to_string(hc["timeout"] || ""),
      "retries" => to_string(hc["retries"] || ""),
      "start_period" => to_string(hc["start_period"] || "")
    }

    cond do
      match?(["CMD-SHELL", _cmd | _rest], hc["test"]) ->
        command = Enum.at(hc["test"], 1) || ""
        Map.merge(base, %{"mode" => "command", "shell" => true, "command" => command})

      match?(["CMD" | _args], hc["test"]) ->
        args = tl(hc["test"])
        Map.merge(base, %{"mode" => "command", "shell" => false, "args" => nonempty(args)})

      is_list(hc["test"]) and hc["test"] != [] ->
        Map.merge(base, %{"mode" => "command", "shell" => false, "args" => nonempty(hc["test"])})

      present?(hc["command"]) ->
        Map.merge(base, %{"mode" => "command", "shell" => true, "command" => hc["command"]})

      present?(hc["path"]) ->
        Map.merge(base, %{"mode" => "path", "path" => hc["path"]})

      true ->
        Map.put(base, "mode", "none")
    end
  end

  defp nonempty([]), do: [""]
  defp nonempty(args), do: args

  @doc """
  The Docker `Test` array this form emits, or `nil` when it declares no check.

  Mirrors `SpecBuilder.health_test/3` so the preview under the editor cannot promise a
  probe the spec builder would not build.
  """
  def health_test(%__MODULE__{health: %{"mode" => "none"}}), do: nil

  def health_test(%__MODULE__{health: %{"mode" => "command"} = h}) do
    if h["shell"] do
      if present?(h["command"]), do: ["CMD-SHELL", h["command"]], else: nil
    else
      case Enum.filter(h["args"], &present?/1) do
        [] -> nil
        argv -> ["CMD" | argv]
      end
    end
  end

  def health_test(%__MODULE__{health: %{"mode" => "path"} = h} = form) do
    if present?(h["path"]) do
      {port, _source} = probe_port(form)
      url = "#{form.backend_scheme}://localhost:#{port}#{h["path"]}"

      [
        "CMD-SHELL",
        "wget -qO- #{probe_flags(form.backend_scheme, :wget)}#{url} >/dev/null 2>&1 || " <>
          "curl -fsS #{probe_flags(form.backend_scheme, :curl)}#{url} >/dev/null 2>&1 || exit 1"
      ]
    end
  end

  def health_test(%__MODULE__{}), do: nil

  # The probe dials `localhost`, so a certificate issued for the app's real hostname
  # never matches and a self-signed one has no chain to follow.
  defp probe_flags("https", :wget), do: "--no-check-certificate "
  defp probe_flags("https", :curl), do: "-k "
  defp probe_flags(_scheme, _tool), do: ""

  @doc "True when this form declares a usable check at all."
  def declares_health?(%__MODULE__{} = form), do: health_test(form) != nil

  @doc """
  The port an HTTP path check probes, and where that port came from.

  `:route` is a decision the operator made; `:guess` mirrors `SpecBuilder.guess_port/1`,
  which takes the first non-UDP port because Traefik's http services speak TCP only;
  `:fallback` is the literal `80` that function ends in when there is no port at all.
  """
  def probe_port(%__MODULE__{} = form) do
    routed =
      form.routes
      |> Enum.map(& &1["port"])
      |> Enum.find(&present?/1)

    if routed do
      {to_string(routed), :route}
    else
      guess_port(form.ports)
    end
  end

  defp guess_port(ports) do
    routable = Enum.filter(ports, &(&1["protocol"] != "udp" and present?(&1["internal"])))

    pick =
      Enum.find(routable, &(&1["role"] == "web")) ||
        Enum.find(routable, &(&1["optional"] != true)) ||
        List.first(routable)

    if pick, do: {to_string(pick["internal"]), :guess}, else: {"80", :fallback}
  end

  # ------------------------------------------------------------------
  # Writing it back
  # ------------------------------------------------------------------

  @doc """
  Turns the form into the attrs `Deployments.update_deployment/2` takes.

  One map, written in one save. The three forms this replaced each wrote their own
  subset, so an edit that spanned two of them recreated the container twice.
  """
  def to_attrs(%__MODULE__{} = form, %Deployment{app_template: template} = deployment) do
    {domain, extra_routes, additional_domains} = split_routes(form)

    %{
      image_override: image_override(form, deployment),
      exposure_mode_override: exposure(form),
      network_parent_id: network_parent_id(form),
      domain: domain,
      routed_port: primary_port(form),
      extra_routes: extra_routes,
      additional_domains: additional_domains,
      ports_override: ports_override(form),
      proxy_options: proxy_options(form),
      restart_policy_override: blank_to_nil(form.restart_policy),
      replicas_override: parse_replicas(form.replicas),
      command_override:
        override_or_inherit(split_words(form.command), List.wrap(template.command)),
      entrypoint_override:
        override_or_inherit(split_words(form.entrypoint), List.wrap(template.entrypoint)),
      network_aliases_override:
        override_or_inherit(split_words(form.aliases), List.wrap(template.network_aliases)),
      capabilities_add_override:
        override_or_inherit(
          RuntimeSpec.parse_capabilities(form.caps_add),
          RuntimeSpec.parse_capabilities(template.capabilities_add)
        ),
      capabilities_drop_override:
        override_or_inherit(
          RuntimeSpec.parse_capabilities(form.caps_drop),
          RuntimeSpec.parse_capabilities(template.capabilities_drop)
        ),
      devices_override:
        override_or_inherit(
          RuntimeSpec.parse_devices(form.devices),
          RuntimeSpec.parse_devices(template.devices || [])
        ),
      sysctls_override:
        override_or_inherit(
          sysctls_of(form.sysctls),
          RuntimeSpec.parse_sysctls(template.sysctls || %{})
        ),
      resource_limits_override: limits_override(form),
      health_check_override: health_override(form, deployment)
    }
  end

  # nil means "inherit the catalog", which is not the same as pinning the tag the
  # catalog happens to carry today: a pinned image survives a catalog bump and an
  # inherited one is meant to follow it.
  defp image_override(form, %Deployment{app_template: template}) do
    case String.trim(form.image || "") do
      "" -> nil
      image when image == template.image -> nil
      image -> image
    end
  end

  defp network_parent_id(%__MODULE__{namespace: "donor", donor_id: id}) do
    case Integer.parse(to_string(id)) do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp network_parent_id(%__MODULE__{}), do: nil

  # The unified table, split back into the three columns the schema keeps.
  #
  # The first row with a host is the primary: it becomes `domain` and `routed_port`, and
  # Traefik serves it as the whole host. Rows on that same host are extra PATH routes;
  # rows on any other host are alias domains, which carry their own path and port.
  defp split_routes(%__MODULE__{namespace: "host"}), do: {nil, [], []}

  defp split_routes(%__MODULE__{} = form) do
    case form |> live_routes() |> expand_hosts() |> dedupe_routes() do
      [] ->
        {nil, [], []}

      [primary | rest] ->
        host = String.trim(primary["host"])

        {same_host, other_hosts} =
          Enum.split_with(rest, &(Hostname.normalize(&1["host"]) == Hostname.normalize(host)))

        extra_routes =
          same_host
          |> Enum.filter(&(present?(&1["path_prefix"]) and present?(&1["port"])))
          |> Enum.map(
            &%{"path_prefix" => String.trim(&1["path_prefix"]), "port" => to_int(&1["port"])}
          )

        additional_domains =
          Enum.map(
            other_hosts,
            &%{
              "host" => String.trim(&1["host"]),
              "path_prefix" => blank_to_nil(String.trim(&1["path_prefix"] || "")),
              "port" => to_int(&1["port"])
            }
          )

        {host, extra_routes, additional_domains}
    end
  end

  # A host cell holding "a.example.com, b.example.com" becomes two rows. The wizard's
  # primary-domain field has always accepted a comma-joined list, and the two inputs have
  # to agree on what a comma means or pasting the same value into each gives different
  # results.
  defp expand_hosts(routes) do
    Enum.flat_map(routes, fn route ->
      case Hostname.split(route["host"]) do
        [] -> []
        hosts -> Enum.map(hosts, &Map.put(route, "host", &1))
      end
    end)
  end

  # Two rows that normalize to the same host AND path are two routers racing for one
  # certificate. The FIRST wins: a row typed in full carries a path and a port, and one
  # lifted out of a comma-joined list carries neither, so letting the later bare one
  # through would strip the scoping off an alias already configured.
  defp dedupe_routes(routes) do
    routes
    |> Enum.uniq_by(&{Hostname.normalize(&1["host"]), String.trim(&1["path_prefix"] || "")})
    |> Enum.with_index(fn route, idx -> Map.put(route, "primary", idx == 0) end)
  end

  defp primary_port(%__MODULE__{} = form) do
    case form |> live_routes() |> expand_hosts() |> dedupe_routes() do
      [primary | _rest] -> to_int(primary["port"])
      [] -> nil
    end
  end

  # An empty list is not "inherit" — `Access.effective_ports/1` only inherits on nil, so
  # writing `[]` would win and leave the proxy pointed at the fallback port 80.
  defp ports_override(%__MODULE__{} = form) do
    ports =
      form.ports
      |> Enum.reject(&(String.trim(to_string(&1["internal"])) == ""))
      |> Enum.map(fn port ->
        %{
          "internal" => port["internal"],
          "external" => port["external"],
          "description" => port["description"] || "",
          "optional" => port["optional"] == true,
          "role" => port["role"] || "other",
          "protocol" => Access.port_protocol(port),
          "host_ip" => host_ip(port),
          # In the host's own namespace nothing is mapped, so nothing is published
          # either — the ports are still stored because the healthcheck reads them.
          "published" => form.namespace == "own" and port["exposure"] == "host"
        }
      end)

    if ports == [], do: nil, else: ports
  end

  defp host_ip(%{"host_ip" => ip}) when ip in [nil, "", "0.0.0.0"], do: nil
  defp host_ip(%{"host_ip" => ip}) when is_binary(ip), do: String.trim(ip)
  defp host_ip(_port), do: nil

  defp proxy_options(%__MODULE__{} = form) do
    if routes?(form) do
      %{"sticky" => form.sticky == true, "backend_scheme" => scheme(form.backend_scheme)}
    else
      %{}
    end
  end

  # A stale tab or a hand-built payload can post anything, and "anything" fails the
  # changeset rather than quietly meaning plaintext — taking the whole save with it.
  defp scheme("https"), do: "https"
  defp scheme(_value), do: "http"

  @doc """
  Whether a field stores an override or keeps following the catalog.

  There used to be an explicit "inherit / custom" toggle beside every one of these,
  because a blank field could not say whether an empty command meant "inherit the
  catalog's" or "run nothing". The toggle answered that at the cost of never showing
  the operator what they were inheriting — the field sat empty under the word
  "inherit", and the only way to learn the catalog's actual command was to leave.

  The editor now renders the EFFECTIVE value: the catalog's command is typed into the
  box, every capability is listed with the ones that are on ticked, the inherited
  devices are real rows. That makes the ambiguity answerable by comparison instead —
  a value still equal to the catalog's keeps inheriting, and any edit away from it is
  an override, including an edit down to nothing.

  Editing a field back to the catalog's value returns it to inheriting, which is the
  same rule the image field has always had: typing the catalog's own image back in means
  follow, not pin.
  """
  def override_or_inherit(value, catalog_value) do
    if value == catalog_value, do: nil, else: value
  end

  defp limits_override(%__MODULE__{} = form) do
    limits =
      %{
        "memory_mb" => parse_pos_int(form.memory_mb),
        "cpu_shares" => parse_pos_int(form.cpu_shares),
        "gpu" => gpu_override(form)
      }
      |> Enum.reject(fn {_key, value} -> is_nil(value) end)
      |> Map.new()

    if limits == %{}, do: nil, else: limits
  end

  # A GPU is a reservation, so it rides in resource_limits. "None" means no GPU rather
  # than "inherit": the limits map is a wholesale override, and a half-map would drop
  # the memory limit along with it.
  defp gpu_override(%__MODULE__{gpu_vendor: vendor} = form) when vendor in ["nvidia", "amd"] do
    %{
      "vendor" => vendor,
      "count" => parse_pos_int(form.gpu_count) || 1,
      # Matched byte-for-byte against the node's daemon.json under Swarm, so it is
      # prefilled from what the cluster advertises rather than from a convention.
      "kind" => blank_default(form.gpu_kind, GpuSpec.default_kind(vendor)),
      "devices" => blank_default(form.gpu_devices, "all")
    }
  end

  defp gpu_override(%__MODULE__{}), do: nil

  @doc """
  The healthcheck map to store, or `nil` to keep inheriting the template's.

  A deployment that has never overridden its check and has not had it edited keeps
  inheriting: writing the template's own check back as an override would freeze it, so
  a later catalog fix would stop reaching this deployment.
  """
  def health_override(%__MODULE__{} = form, %Deployment{app_template: template}) do
    if form.health == read_health(template.health_check),
      do: nil,
      else: build_health(form)
  end

  defp build_health(%__MODULE__{health: %{"mode" => "none"}}), do: %{}

  defp build_health(%__MODULE__{health: h} = form) do
    check =
      case {h["mode"], h["shell"]} do
        {"command", true} -> %{"command" => String.trim(h["command"] || "")}
        {"command", false} -> %{"test" => health_test(form) || []}
        {"path", _shell} -> %{"path" => String.trim(h["path"] || "")}
        _other -> %{}
      end

    Enum.reduce(~w(interval timeout retries start_period), check, fn key, acc ->
      case parse_pos_int(h[key]) do
        nil -> acc
        value -> Map.put(acc, key, value)
      end
    end)
  end

  # ------------------------------------------------------------------
  # Diff
  # ------------------------------------------------------------------

  @doc """
  What changed between the saved configuration and the edited one, as rows the review
  sheet renders.

  The point of the sheet is that the save recreates the container, and an operator who
  has edited four cards cannot hold all of it in their head — least of all the derived
  `exposure_mode`, which nothing on the page asks for directly.
  """
  def diff(%__MODULE__{} = base, %__MODULE__{} = current) do
    [
      {"Image", & &1.image},
      {"Namespace", &namespace_label/1},
      {"Authentication", &auth_label/1},
      {"Restart policy", & &1.restart_policy},
      {"Replicas", & &1.replicas},
      {"Command", &blank_dash(&1.command)},
      {"Entrypoint", &blank_dash(&1.entrypoint)},
      {"Network aliases", &blank_dash(&1.aliases)},
      {"Capabilities added", &caps_label(&1.caps_add)},
      {"Capabilities dropped", &caps_label(&1.caps_drop)},
      {"Devices", &devices_label/1},
      {"Sysctls", &sysctls_label/1},
      {"Memory (MB)", &blank_dash(&1.memory_mb)},
      {"CPU shares", &blank_dash(&1.cpu_shares)},
      {"GPU", &gpu_label/1},
      {"Health check", &health_label/1},
      {"Sticky sessions", &if(&1.sticky, do: "on", else: "off")},
      {"Ports", &ports_label/1},
      {"Routes", &routes_label/1},
      {"exposure_mode (derived)", &exposure/1}
    ]
    |> Enum.map(fn {label, read} -> {label, read.(base), read.(current)} end)
    |> Enum.reject(fn {_label, was, now} -> was == now end)
    |> Enum.map(fn {label, was, now} -> %{label: label, was: was, now: now} end)
  end

  defp namespace_label(%{namespace: "own"}), do: "its own network"
  defp namespace_label(%{namespace: "host"}), do: "the host's network"
  defp namespace_label(%{donor_id: id}), do: "through deployment ##{id}"

  defp auth_label(%{auth: "public"}), do: "none"
  defp auth_label(%{auth: "sso_protected"}), do: "SSO"
  defp auth_label(%{auth: "private"}), do: "LAN only"
  defp auth_label(%{auth: auth}), do: to_string(auth)

  defp caps_label(caps), do: caps |> Enum.sort() |> Enum.join(", ") |> blank_dash("none")

  defp devices_label(%{devices: rows}) do
    rows
    |> Enum.reject(&(String.trim(&1["host_path"] || "") == ""))
    |> Enum.map_join(", ", &"#{&1["host_path"]}:#{&1["container_path"]}")
    |> blank_dash()
  end

  defp sysctls_label(%{sysctls: rows}) do
    rows
    |> Enum.reject(&(String.trim(&1["key"] || "") == ""))
    |> Enum.map_join(", ", &"#{&1["key"]}=#{&1["value"]}")
    |> blank_dash()
  end

  defp gpu_label(%{gpu_vendor: vendor}) when vendor in ["nvidia", "amd"], do: vendor
  defp gpu_label(_form), do: "none"

  defp health_label(%__MODULE__{health: h} = form) do
    case health_test(form) do
      nil ->
        "not declared"

      test ->
        defaults = @health_defaults

        "#{inspect(test)} every #{h["interval"] |> blank(defaults["interval"])}s, " <>
          "timeout #{h["timeout"] |> blank(defaults["timeout"])}s, " <>
          "#{h["retries"] |> blank(defaults["retries"])} retries, " <>
          "start #{h["start_period"] |> blank(defaults["start_period"])}s"
    end
  end

  defp ports_label(%__MODULE__{} = form) do
    form.ports
    |> Enum.reject(&(String.trim(to_string(&1["internal"])) == ""))
    |> Enum.map_join(", ", fn port ->
      binding =
        if port["exposure"] == "host" and form.namespace == "own" do
          " -> #{port["host_ip"] || "0.0.0.0"}:#{blank(port["external"], port["internal"])}"
        else
          ""
        end

      "#{port["internal"]}/#{port["protocol"]} #{port["exposure"]}#{binding}"
    end)
    |> blank_dash("none")
  end

  defp routes_label(%__MODULE__{} = form) do
    form
    |> live_routes()
    |> Enum.map_join(", ", &"#{&1["host"]}#{&1["path_prefix"]} -> :#{&1["port"]}")
    |> blank_dash("none")
  end

  # ------------------------------------------------------------------
  # Runtime list fields
  # ------------------------------------------------------------------

  # ------------------------------------------------------------------
  # Small helpers
  # ------------------------------------------------------------------

  # One argument per LINE, never split on whitespace: `--config /etc/app with spaces.conf`
  # is one argument, and the alternative to a line break is implementing shell quoting in
  # a form field.
  defp join_words(nil), do: ""
  defp join_words(words) when is_list(words), do: Enum.join(words, "\n")
  defp join_words(value) when is_binary(value), do: value
  defp join_words(_value), do: ""

  defp split_words(text) do
    (text || "")
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp sysctl_rows_of(sysctls) when is_map(sysctls) do
    sysctls
    |> Enum.map(fn {key, value} -> %{"key" => key, "value" => to_string(value)} end)
    |> Enum.sort_by(& &1["key"])
  end

  defp sysctl_rows_of(_sysctls), do: []

  defp sysctls_of(rows) do
    rows
    |> Enum.reject(&(String.trim(&1["key"] || "") == ""))
    |> Map.new(&{String.trim(&1["key"]), String.trim(to_string(&1["value"] || ""))})
  end

  # A checkbox list posts only the boxes that are ticked, so an empty selection posts no
  # key at all -- indistinguishable from "this control was not rendered". The form pairs
  # each list with a hidden sentinel field, and that is what tells the two apart.
  defp carry_caps(nil, current), do: current
  defp carry_caps(caps, _current), do: RuntimeSpec.parse_capabilities(List.wrap(caps) -- [""])

  defp present?(value) when is_binary(value), do: String.trim(value) != ""
  defp present?(value) when is_integer(value), do: true
  defp present?(_value), do: false

  defp blank_to_nil(value) when value in [nil, ""], do: nil
  defp blank_to_nil(value), do: value

  defp blank(value, fallback) do
    if present?(value), do: value, else: to_string(fallback)
  end

  defp blank_dash(value, fallback \\ "—") do
    if present?(value), do: to_string(value), else: fallback
  end

  defp to_int(value) do
    case value |> to_string() |> Integer.parse() do
      {parsed, ""} -> parsed
      _ -> nil
    end
  end

  defp parse_pos_int(value) do
    case value |> to_string() |> Integer.parse() do
      {parsed, _rest} when parsed > 0 -> parsed
      _ -> nil
    end
  end

  defp parse_replicas(value), do: parse_pos_int(value)

  defp blank_default(value, default) when is_binary(value) do
    case String.trim(value) do
      "" -> default
      trimmed -> trimmed
    end
  end

  defp blank_default(_value, default), do: default
end
