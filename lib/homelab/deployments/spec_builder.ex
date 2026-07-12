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

  NOTE: the older per-deployment network (`deployment_network/2`) is retained only
  for the vestigial `publish`/`unpublish` calls (Traefik was never actually on those
  nets); routing is now enforced by Traefik's Docker provider over the shared
  ingress. Gating a route on deployment *status* (vs container-running) is a
  follow-up: it should toggle the web's ingress membership, not a Traefik-per-net.
  """

  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.Access

  @type service_spec :: %{
          service_name: String.t(),
          image: String.t(),
          user: String.t() | nil,
          env: map(),
          volumes: [map()],
          ports: [map()],
          network: String.t(),
          labels: map(),
          replicas: pos_integer(),
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
      # Access model: only :host binds host ports; proxy/:service never do.
      service_mode? = Access.effective_exposure(deployment) == :service
      ports = build_ports(deployment)

      # Network model (see moduledoc): the PRIMARY network is the tenant-scoped
      # PRIVATE app network — web ↔ its datastores talk here, and Traefik never
      # joins it. A routed web tier is *additionally* attached to the shared INGRESS
      # network by the orchestrator (on `traefik.enable`); a `:service` datastore
      # stays on the app network only, so it is never publicly reachable. Traefik
      # reaches the web over the ingress network, named in the routing label below.
      primary_network = tenant_network(tenant)
      bridge_networks = []

      base_labels = build_labels(template, tenant, deployment)
      routing_labels = build_routing_labels(deployment, Homelab.Infrastructure.internal_network())

      spec = %{
        service_name: service_name(tenant, template),
        image: template.image,
        # Preserve the adopted container's uid:gid (never chown adopted data). nil
        # for greenfield deploys, which run as the image's default user.
        user: template.user,
        env: build_env(template, tenant, deployment),
        volumes: build_volumes(template, tenant),
        ports: ports,
        network: primary_network,
        bridge_networks: bridge_networks,
        labels: Map.merge(base_labels, routing_labels),
        replicas: 1,
        memory_limit: memory_limit_bytes(Access.effective_resource_limits(deployment)),
        cpu_limit: cpu_limit_nanocpus(Access.effective_resource_limits(deployment)),
        tenant_id: to_string(tenant.id),
        deployment_id: to_string(deployment.id),
        service_mode: service_mode?,
        health_check:
          build_health_check(
            Access.effective_health_check(deployment),
            Access.effective_ports(deployment)
          )
      }

      {:ok, spec}
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
  the primary port; `test`/`command` checks pass through.
  """
  def build_health_check(health_check, ports) do
    hc = health_check || %{}

    case health_test(hc, primary_port(ports || [])) do
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

  defp build_env(template, tenant, deployment) do
    base_env = template.default_env || %{}
    oidc_env = if template.auth_integration, do: oidc_env_vars(tenant, template), else: %{}
    overrides = deployment.env_overrides || %{}

    base_env
    |> Map.merge(oidc_env)
    |> Map.merge(overrides)
  end

  defp oidc_env_vars(tenant, template) do
    domain = Homelab.Config.base_domain()

    %{
      "OIDC_CLIENT_ID" => "homelab_#{tenant.slug}_#{template.slug}",
      "OIDC_ISSUER" => "https://auth.#{domain}/application/o/#{template.slug}/",
      "OIDC_REDIRECT_URI" => "https://#{template.slug}.#{tenant.slug}.#{domain}/callback"
    }
  end

  defp build_volumes(template, tenant) do
    (template.volumes || [])
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
    port = primary_port(Access.effective_ports(deployment))
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
      "traefik.http.services.#{router}.loadbalancer.server.port" => to_string(port)
    }

    base
    |> Map.merge(exposure_middleware_labels(router, exposure))
    |> Map.merge(sticky_labels(router, deployment))
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

  defp primary_port(ports) when is_list(ports) do
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
