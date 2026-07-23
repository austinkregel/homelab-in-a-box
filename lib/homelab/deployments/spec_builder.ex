defmodule Homelab.Deployments.SpecBuilder do
  @moduledoc """
  Converts an AppTemplate + Tenant + user overrides into a fully resolved
  orchestrator-agnostic service spec.

  This module enforces tenant isolation invariants:
  - Volume paths are scoped to the tenant slug
  - Networks are scoped to the tenant slug
  - OIDC env vars are injected when auth_integration is true
  - Required env vars are validated

  ## Network model

  Two networks, by role:

    * **App network** (`homelab_tenant_<tenant>`) — a PRIVATE, tenant-scoped network
      that every container in the tenant sits on. This is where a web tier reaches
      its datastores. **Traefik never joins it**, so a datastore on it is not
      publicly reachable. It is each container's primary `NetworkMode`.
    * **Ingress network** (`Infrastructure.internal_network/0`, `homelab-iab-internal`)
      — the shared network Traefik lives on. Only a ROUTED tier (a proxy
      `exposure_mode` WITH a domain, i.e. `traefik.enable=true`) is additionally
      attached to it, by the orchestrator. The routing label (`traefik.swarm.network`
      under Swarm, `traefik.docker.network` otherwise — never both) points here so
      Traefik resolves the backend over ingress.

  So: `web` is dual-homed (app net + ingress); `:service` datastores stay on the app
  net only. Sharing a datastore across apps is done by multi-homing it onto the
  consuming app's network — never by exposing it publicly.

  ### Host networking

  `:host_network` opts out of the model above entirely: the container is placed in the
  HOST's network namespace (`network: "host"`, `host_network: true`), which is what an
  app needing broadcast/multicast discovery (Home Assistant, Plex, Jellyfin, AdGuard,
  anything doing mDNS/SSDP/DHCP) actually requires — a published port forwards unicast
  TCP and drops the discovery traffic on the floor.

  The spec that comes out is deliberately *narrower*, because the daemon rejects every
  one of these alongside host networking rather than ignoring them:

    * `ports: []` — there is no mapping to make; the container listens on the host's
      ports directly. Docker discards `PortBindings` in host mode with a warning.
    * `network_aliases: []` — a network-scoped alias is a user-defined-network feature.
    * no ingress/bridge attachment — a container in the host namespace has no endpoint
      on any other network and cannot be connected to one.

  That last point is why host networking is exclusive with the proxy modes and not a
  flag on top of them: Traefik's Docker provider has no backend IP to route to.

  NOTE: the older per-deployment network (`deployment_network/2`) is retained only
  for the vestigial `publish`/`unpublish` calls (Traefik was never actually on those
  nets); routing is now enforced by Traefik's Docker provider over the shared
  ingress. Gating a route on deployment *status* (vs container-running) is a
  follow-up: it should toggle the web's ingress membership, not a Traefik-per-net.
  """

  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.Access
  alias Homelab.Deployments.GpuSpec

  @type image_source :: :registry | :local

  @type service_spec :: %{
          service_name: String.t(),
          image: String.t(),
          image_source: image_source(),
          user: String.t() | nil,
          env: map(),
          volumes: [map()],
          ports: [map()],
          network: String.t(),
          host_network: boolean(),
          labels: map(),
          replicas: pos_integer(),
          restart_policy: String.t(),
          memory_limit: pos_integer(),
          cpu_limit: pos_integer(),
          tenant_id: String.t(),
          deployment_id: String.t()
        }

  @spec build(Deployment.t()) :: {:ok, service_spec()} | {:error, term()}
  def build(%Deployment{} = deployment) do
    template = deployment.app_template
    tenant = deployment.tenant

    with :ok <- validate_required_env(template, deployment.env_overrides) do
      # Access model: only :host binds host ports; proxy/:service never do, and
      # :host_network has nothing to bind — it is already on the host's ports.
      service_mode? = Access.effective_exposure(deployment) == :service
      host_network? = Access.host_network_mode?(deployment)
      ports = build_ports(deployment)

      # Network model (see moduledoc): the PRIMARY network is the tenant-scoped
      # PRIVATE app network — web ↔ its datastores talk here, and Traefik never
      # joins it. A routed web tier is *additionally* attached to the shared INGRESS
      # network by the orchestrator (on `traefik.enable`); a `:service` datastore
      # stays on the app network only, so it is never publicly reachable. Traefik
      # reaches the web over the ingress network, named in the routing label below.
      #
      # `:host_network` replaces the primary with Docker's predefined `host` network:
      # no tenant isolation, because there is no network to isolate it on.
      primary_network = if host_network?, do: "host", else: tenant_network(tenant)
      bridge_networks = []

      base_labels = build_labels(template, tenant, deployment)
      routing_labels = build_routing_labels(deployment, Homelab.Infrastructure.internal_network())

      gpu = GpuSpec.parse(Access.effective_resource_limits(deployment))

      spec = %{
        service_name: service_name(tenant, template),
        image: Access.effective_image(deployment),
        # Whether this image MUST come from a registry. Decides what a failed pull
        # means -- see image_source/1.
        image_source: image_source(deployment, template),
        # Preserve the adopted container's uid:gid (never chown adopted data). nil
        # for greenfield deploys, which run as the image's default user.
        user: template.user,
        env: build_env(template, tenant, deployment, gpu),
        volumes: build_volumes(template, tenant, Access.effective_volumes(deployment)),
        ports: ports,
        network: primary_network,
        bridge_networks: bridge_networks,
        # The container lives in the HOST's network namespace. The drivers read this
        # rather than string-matching the network name, and it is what tells them to
        # skip everything host mode forbids (see moduledoc).
        host_network: host_network?,
        # Extra names this container answers to on its network. Adoption fills these with
        # the original's compose service name, so the rest of the stack keeps resolving it.
        # Meaningless — and rejected by the daemon — on the host network, which has no
        # embedded DNS to register a name with.
        network_aliases:
          if(host_network?, do: [], else: Access.effective_network_aliases(deployment)),
        # nil = the image's default. Adoption sets these to what the original actually ran.
        command: Access.effective_command(deployment),
        entrypoint: Access.effective_entrypoint(deployment),
        labels: Map.merge(base_labels, routing_labels),
        replicas: Access.effective_replicas(deployment),
        # How the container behaves when it exits. Both drivers hardcoded on-failure/3
        # before this could be chosen; that is still what nil resolves to.
        restart_policy: Access.effective_restart_policy(deployment),
        memory_limit: memory_limit_bytes(Access.effective_resource_limits(deployment)),
        cpu_limit: cpu_limit_nanocpus(Access.effective_resource_limits(deployment)),
        # Vendor INTENT, not an API payload: Engine passes the device directly, Swarm
        # can only reserve a generic resource and let a runtime hook inject it. The
        # drivers translate. nil = no GPU.
        gpu: gpu,
        tenant_id: to_string(tenant.id),
        deployment_id: to_string(deployment.id),
        service_mode: service_mode?,
        # Probes the SAME port the proxy forwards to. If the routed port is wrong,
        # the container fails its healthcheck at deploy time instead of coming up
        # "healthy" and quietly serving 502s through Traefik.
        health_check:
          build_health_check(
            Access.effective_health_check(deployment),
            routed_port(deployment)
          )
      }

      {:ok, spec}
    end
  end

  # Whether the image MUST be pulled, which is what a failed pull means.
  #
  # `:local` is not a convenience — it is a statement that the image has no registry
  # behind it. An ADOPTED container is by definition already running its image, and a
  # Workbench build exists only in the daemon's local store. Failing those rolls a
  # cutover back on an image the daemon was holding the whole time.
  #
  # Everything else is `:registry`, and a failed pull is fatal. This used to be decided
  # on the error path instead — any pull failure was survivable if the daemon happened
  # to hold *something* under that ref — so a version change could report success while
  # running exactly the image it was meant to replace.
  #
  # An explicit image_override forces `:registry` whatever the source. An operator who
  # names a ref wants THAT ref; silently running a stale local image is never the right
  # answer, including when upgrading an adopted app off its adopted image.
  defp image_source(deployment, template) do
    cond do
      Access.image_overridden?(deployment) -> :registry
      template.source in ["adopted", "built"] -> :local
      true -> :registry
    end
  end

  @doc """
  True when a template declares a usable healthcheck — an explicit command
  (`"test"`/`"command"`) or a non-empty HTTP `"path"`. An empty path (used by
  non-HTTP services that omit a check) does NOT count; those fall back to a
  running-and-stable readiness window. Never guesses an HTTP probe.
  """
  def declares_healthcheck?(%{health_check: hc}), do: declares_healthcheck?(hc)
  def declares_healthcheck?(hc) when is_map(hc), do: health_test(hc, nil) != nil
  def declares_healthcheck?(_), do: false

  @doc """
  Builds a Docker `Healthcheck` payload from a declared healthcheck map, or `nil`
  when none is declared. HTTP `path` checks become a `wget`/`curl` probe against
  the routed port; `test`/`command` checks pass through.
  """
  def build_health_check(health_check, port) do
    hc = health_check || %{}

    case health_test(hc, port) do
      nil ->
        nil

      test ->
        %{
          "Test" => test,
          "Interval" => seconds_to_ns(hc["interval"] || 30),
          "Timeout" => seconds_to_ns(hc["timeout"] || 10),
          "Retries" => hc["retries"] || 3,
          "StartPeriod" => seconds_to_ns(hc["start_period"] || 10)
        }
    end
  end

  defp health_test(hc, port) do
    cond do
      is_list(hc["test"]) and hc["test"] != [] ->
        hc["test"]

      is_binary(hc["command"]) and hc["command"] != "" ->
        ["CMD-SHELL", hc["command"]]

      is_binary(hc["path"]) and hc["path"] != "" and not is_nil(port) ->
        url = "http://localhost:#{port}#{hc["path"]}"

        [
          "CMD-SHELL",
          "wget -qO- #{url} >/dev/null 2>&1 || curl -fsS #{url} >/dev/null 2>&1 || exit 1"
        ]

      is_binary(hc["path"]) and hc["path"] != "" ->
        # `declares_healthcheck?/1` calls this with port=nil just to detect intent.
        ["CMD-SHELL", "true"]

      true ->
        nil
    end
  end

  defp seconds_to_ns(seconds) when is_integer(seconds), do: seconds * 1_000_000_000
  defp seconds_to_ns(_), do: 30_000_000_000

  @doc """
  Builds a service name from tenant and template slugs.
  The result is always a valid Docker service name.
  """
  def service_name(tenant, template) do
    "homelab_#{sanitize(tenant.slug)}_#{sanitize(template.slug)}"
  end

  @doc """
  Builds a per-deployment isolated network name.
  """
  def deployment_network(tenant, template) do
    deployment_network_for(tenant.slug, template.slug)
  end

  @doc """
  Builds a per-deployment network name directly from tenant and app slugs
  (e.g. from container labels, when no struct is at hand).
  """
  def deployment_network_for(tenant_slug, app_slug)
      when is_binary(tenant_slug) and is_binary(app_slug) do
    "homelab_#{sanitize(tenant_slug)}_#{sanitize(app_slug)}_net"
  end

  @doc """
  Builds the tenant-scoped network name used to bridge related deployments.
  """
  def tenant_network(tenant) do
    "homelab_tenant_#{sanitize(tenant.slug)}"
  end

  defp sanitize(slug) do
    slug
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9_.-]/, "_")
  end

  defp build_env(template, tenant, deployment, gpu) do
    base_env = template.default_env || %{}
    oidc_env = if template.auth_integration, do: oidc_env_vars(tenant, template), else: %{}
    overrides = deployment.env_overrides || %{}

    base_env
    |> Map.merge(oidc_env)
    |> Map.merge(gpu_env(gpu))
    |> Map.merge(overrides)
  end

  # The visible-devices var is what the vendor runtime hook actually reads to decide
  # which GPUs to inject. Under Swarm it is the ONLY injection mechanism (the generic
  # resource merely schedules the task onto a GPU node), so it is not optional there.
  #
  # Merged BEFORE env_overrides, so an operator can still pin a specific device by
  # hand without us clobbering them on the next save.
  defp gpu_env(nil), do: %{}

  defp gpu_env(gpu) do
    {key, value} = GpuSpec.visible_devices_env(gpu)
    %{key => value}
  end

  defp oidc_env_vars(tenant, template) do
    domain = Homelab.Config.base_domain()

    %{
      "OIDC_CLIENT_ID" => "homelab_#{tenant.slug}_#{template.slug}",
      "OIDC_ISSUER" => "https://auth.#{domain}/application/o/#{template.slug}/",
      "OIDC_REDIRECT_URI" => "https://#{template.slug}.#{tenant.slug}.#{domain}/callback"
    }
  end

  defp build_volumes(template, tenant, volumes) do
    volumes
    |> List.wrap()
    |> Enum.map(fn vol ->
      container_path = vol["container_path"] || vol["path"] || "/data"

      case vol["source"] do
        source when is_binary(source) and source != "" ->
          # Adoption passthrough: reference an existing/managed volume by name, or
          # a `type: "bind"` at a host path, exactly as captured — do not compute a
          # synthetic tenant-scoped name that would shadow the real data.
          %{source: source, target: container_path, type: vol["type"] || "volume"}

        _ ->
          %{
            source: volume_name(tenant.slug, template.slug, container_path),
            target: container_path,
            type: "volume"
          }
      end
    end)
  end

  defp volume_name(tenant_slug, app_slug, container_path) do
    path_slug =
      container_path
      |> String.trim_leading("/")
      |> String.replace(~r/[^a-z0-9]+/i, "-")
      |> String.trim("-")

    "homelab-#{sanitize(tenant_slug)}-#{sanitize(app_slug)}-#{path_slug}"
  end

  # Host ports are bound ONLY in :host access mode. Proxy modes (public/
  # sso_protected/private) are reached through Traefik and :service is internal —
  # neither binds a host port, so there's no silent override and a protected app
  # can never be reached on the host bypassing its auth.
  #
  # :host_network binds nothing either, for the opposite reason: the container is
  # ALREADY on the host's ports. Emitting a binding there is not a smaller version of
  # the same thing — the daemon discards it, and a spec that claimed a mapping would
  # have the UI show a host port that no rule anywhere actually created.
  defp build_ports(%Deployment{} = deployment) do
    if Access.effective_exposure(deployment) == :host do
      bind_host_ports(deployment)
    else
      []
    end
  end

  defp bind_host_ports(deployment) do
    Access.effective_ports(deployment)
    |> Enum.filter(fn port -> port["published"] == true end)
    |> Enum.map(fn port ->
      internal = to_string(port["internal"] || port["container_port"])

      external =
        to_string(
          port["external"] || port["host_port"] || port["internal"] || port["container_port"]
        )

      role = port["role"] || Homelab.Catalog.Enrichers.PortRoles.infer(internal)

      %{internal: internal, external: external, role: role}
    end)
  end

  defp build_labels(template, tenant, deployment) do
    base = %{
      "homelab.managed" => "true",
      "homelab.tenant" => tenant.slug,
      "homelab.app" => template.slug,
      "homelab.deployment_id" => to_string(deployment.id),
      "homelab.exposure" => to_string(Access.effective_exposure(deployment))
    }

    # Adopted deployments carry `homelab.adopted=true` so the reconciler's
    # orphan-sweep exemption holds across restarts/recreates, not just at cutover.
    if template.source == "adopted" do
      Map.put(base, "homelab.adopted", "true")
    else
      base
    end
  end

  defp validate_required_env(template, overrides) do
    missing =
      (template.required_env || [])
      |> Enum.reject(fn key -> Map.has_key?(overrides || %{}, key) end)

    case missing do
      [] -> :ok
      keys -> {:error, {:missing_required_env, keys}}
    end
  end

  # A Traefik route is emitted only for a proxy access mode WITH a domain. A
  # :host or :service deployment is never proxied, even if a stray domain is set,
  # so there are no dead routes.
  defp build_routing_labels(%Deployment{domain: domain} = deployment, network)
       when is_binary(domain) and domain != "" do
    if Access.proxy_mode?(deployment) do
      proxy_labels(deployment, domain, network)
    else
      %{}
    end
  end

  defp build_routing_labels(_deployment, _network), do: %{}

  defp proxy_labels(deployment, domain, network) do
    router = sanitize_domain(domain)
    port = routed_port(deployment)
    exposure = to_string(Access.effective_exposure(deployment))

    base = %{
      "traefik.enable" => "true",
      # A routed workload is multi-homed (its own app network + the ingress
      # network), so Traefik must be told which one to reach the backend on.
      #
      # Emit EXACTLY ONE of the provider-specific forms. Traefik does not ignore the
      # other provider's label — it rejects a workload carrying both outright
      # ("both Docker and Swarm labels are defined") and skips it, leaving the app
      # unrouted. Which one is right follows how the workload is deployed: a Swarm
      # service is discovered by the swarm provider, a plain container by the docker
      # one.
      network_label_key() => network,
      "traefik.http.routers.#{router}.rule" => "Host(`#{domain}`)",
      "traefik.http.routers.#{router}.entrypoints" => "web,websecure",
      "traefik.http.routers.#{router}.tls" => "true",
      "traefik.http.routers.#{router}.tls.certresolver" => "letsencrypt",
      # Named explicitly, ALWAYS -- not only when extra routes exist. Traefik auto-links
      # a router to a same-named service only while the workload defines exactly one.
      # The moment a second appears, every router must name its service or Traefik
      # rejects the whole workload and the app loses its WORKING route too. Emitting it
      # unconditionally means adding a route can never break the route that already
      # worked.
      "traefik.http.routers.#{router}.service" => router,
      "traefik.http.services.#{router}.loadbalancer.server.port" => to_string(port)
    }

    base
    |> Map.merge(exposure_middleware_labels(router, exposure))
    |> Map.merge(sticky_labels(router, deployment))
    |> Map.merge(extra_route_labels(deployment, router, domain))
  end

  @doc """
  Routers + services for a deployment's `extra_routes` — a path on the same host that
  must reach a DIFFERENT container port.

  One backend port per workload holds until an app serves a second protocol from a
  second port. aut.hair does: Laravel on 8000, Reverb (websockets) on 6001, and the
  browser opens `wss://aut.hair/app` — port 443, path `/app`. The HTTP server does not
  speak the websocket protocol, so without a second route every handshake died on 8000.

  No priority label is set, deliberately. Traefik's default priority is the RULE LENGTH,
  and `Host(...) && PathPrefix(...)` is strictly longer than the bare `Host(...)` it
  extends — so the specific route always outranks the catch-all, by construction. An
  explicit number would have to be kept above whatever the base rule's length happens to
  be, which is a trap waiting for a longer domain.
  """
  def extra_route_labels(deployment, router, domain) do
    deployment
    |> Map.get(:extra_routes)
    |> List.wrap()
    |> Enum.flat_map(fn route ->
      path = route["path_prefix"]
      port = route["port"]

      if is_binary(path) and is_integer(port) do
        name = "#{router}-#{sanitize_path(path)}"

        [
          {"traefik.http.routers.#{name}.rule", "Host(`#{domain}`) && PathPrefix(`#{path}`)"},
          {"traefik.http.routers.#{name}.entrypoints", "web,websecure"},
          {"traefik.http.routers.#{name}.tls", "true"},
          {"traefik.http.routers.#{name}.tls.certresolver", "letsencrypt"},
          {"traefik.http.routers.#{name}.service", name},
          {"traefik.http.services.#{name}.loadbalancer.server.port", to_string(port)}
        ]
      else
        []
      end
    end)
    |> Map.new()
  end

  # A router name is part of a label KEY, so it has to be a plain token: "/app" ->
  # "app", "/apps/events" -> "apps-events".
  defp sanitize_path(path) do
    path
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end

  # Websockets need no Traefik label — the HTTP upgrade is proxied transparently.
  # What DOES break them is load balancing: with more than one replica Traefik
  # round-robins, so a websocket (or LiveView) reconnect can land on a different
  # container than the one holding the session. A sticky cookie pins a client to the
  # replica it first reached.
  defp sticky_labels(router, deployment) do
    if sticky?(deployment) do
      %{
        "traefik.http.services.#{router}.loadbalancer.sticky.cookie" => "true",
        "traefik.http.services.#{router}.loadbalancer.sticky.cookie.name" => "homelab_#{router}",
        # The session cookie rides the same HTTPS the router already enforces.
        "traefik.http.services.#{router}.loadbalancer.sticky.cookie.secure" => "true",
        "traefik.http.services.#{router}.loadbalancer.sticky.cookie.httponly" => "true"
      }
    else
      %{}
    end
  end

  defp sticky?(%{proxy_options: %{"sticky" => true}}), do: true
  defp sticky?(_deployment), do: false

  # Keyed off the ORCHESTRATOR, not the daemon: Traefik runs both providers on a
  # swarm-enabled daemon, and what decides which one discovers this workload is
  # whether we deploy it as a Swarm service or as a plain container.
  defp network_label_key do
    case Homelab.Config.orchestrator() do
      Homelab.Orchestrators.DockerSwarm -> "traefik.swarm.network"
      _ -> "traefik.docker.network"
    end
  end

  defp exposure_middleware_labels(router, "sso_protected") do
    %{
      "traefik.http.routers.#{router}.middlewares" => "#{router}-auth",
      "traefik.http.middlewares.#{router}-auth.forwardauth.address" =>
        "http://authentik-proxy:9000/outpost.goauthentik.io/auth/nginx",
      "traefik.http.middlewares.#{router}-auth.forwardauth.trustForwardHeader" => "true",
      "traefik.http.middlewares.#{router}-auth.forwardauth.authResponseHeaders" =>
        "X-authentik-username,X-authentik-groups,X-authentik-email"
    }
  end

  defp exposure_middleware_labels(router, "private") do
    %{
      "traefik.http.routers.#{router}.middlewares" => "#{router}-ipallow",
      "traefik.http.middlewares.#{router}-ipallow.ipallowlist.sourcerange" =>
        "10.0.0.0/8,172.16.0.0/12,192.168.0.0/16"
    }
  end

  defp exposure_middleware_labels(_router, "service"), do: %{}

  defp exposure_middleware_labels(_router, _public), do: %{}

  @doc """
  The container port the proxy forwards to, and the port an HTTP healthcheck probes.

  An explicit `routed_port` is a DECISION and always wins. Everything below it is a
  guess, kept only for deployments that never made one.

  The guess is why aut.hair served a 502: `PortRoles.infer/1` calls *every*
  conventional HTTP port "web" (8000 and 8080 are both on the list), so an app
  exposing two of them had its upstream decided by array order — and an operator's
  explicit pick was re-inferred back to "web" on the next save, handing the route to
  whichever port happened to come first. Traefik pointed at a port nothing listened
  on. `role` is a hint about what a port *is*; it must not decide where traffic goes.
  """
  def routed_port(%Deployment{routed_port: port}) when is_integer(port), do: to_string(port)
  def routed_port(%Deployment{} = deployment), do: guess_port(Access.effective_ports(deployment))

  defp guess_port(ports) when is_list(ports) do
    port =
      Enum.find(ports, fn p -> p["role"] == "web" end) ||
        Enum.find(ports, fn p -> !p["optional"] end) ||
        List.first(ports)

    case port do
      nil -> "80"
      p -> to_string(p["internal"] || p["container_port"] || "80")
    end
  end

  defp sanitize_domain(domain) do
    domain
    |> String.downcase()
    |> String.replace(".", "-")
    |> String.replace(~r/[^a-z0-9-]/, "")
  end

  defp memory_limit_bytes(limits) do
    mb = get_in(limits || %{}, ["memory_mb"]) || 256
    mb * 1_048_576
  end

  defp cpu_limit_nanocpus(limits) do
    shares = get_in(limits || %{}, ["cpu_shares"]) || 512
    shares * 1_000_000
  end
end
