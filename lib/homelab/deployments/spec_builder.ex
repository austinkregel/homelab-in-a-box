defmodule Homelab.Deployments.SpecBuilder do
  @moduledoc """
  Converts an AppTemplate + Tenant + user overrides into a fully resolved
  orchestrator-agnostic service spec.

  This module enforces tenant isolation invariants:
  - Volume paths are scoped to the tenant slug
  - Networks are scoped to the tenant slug
  - OIDC env vars are injected when auth_integration is true
  - Required env vars are validated
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

      primary_network = deployment_network(tenant, template)
      bridge_networks = build_bridge_networks(template, tenant)

      base_labels = build_labels(template, tenant, deployment)
      routing_labels = build_routing_labels(deployment, primary_network)

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

  @bridge_env_prefixes ~w(DB_ MYSQL_ POSTGRES_ MONGO_ REDIS_ DATABASE_ MARIADB_)

  defp build_bridge_networks(template, tenant) do
    has_dependencies? = (template.depends_on || []) != []

    has_bridgeable_env? =
      Enum.any?(Map.keys(template.default_env || %{}), fn k ->
        up = String.upcase(k)
        Enum.any?(@bridge_env_prefixes, &String.starts_with?(up, &1))
      end)

    is_infra_image? =
      case classify_image(template.image || "") do
        :service -> false
        _ -> true
      end

    if has_dependencies? or has_bridgeable_env? or is_infra_image? do
      [tenant_network(tenant)]
    else
      []
    end
  end

  defp classify_image(image) do
    name = image |> String.split("/") |> List.last() |> String.split(":") |> List.first() || ""
    downcased = String.downcase(name)

    cond do
      String.contains?(downcased, "mysql") or String.contains?(downcased, "mariadb") -> :database
      String.contains?(downcased, "postgres") -> :database
      String.contains?(downcased, "mongo") -> :database
      String.contains?(downcased, "redis") or String.contains?(downcased, "valkey") -> :cache
      String.contains?(downcased, "minio") or String.contains?(downcased, "s3") -> :storage
      true -> :service
    end
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
    %{
      "homelab.managed" => "true",
      "homelab.tenant" => tenant.slug,
      "homelab.app" => template.slug,
      "homelab.deployment_id" => to_string(deployment.id),
      "homelab.exposure" => to_string(Access.effective_exposure(deployment))
    }
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
      "traefik.docker.network" => network,
      "traefik.http.routers.#{router}.rule" => "Host(`#{domain}`)",
      "traefik.http.routers.#{router}.entrypoints" => "web,websecure",
      "traefik.http.routers.#{router}.tls" => "true",
      "traefik.http.routers.#{router}.tls.certresolver" => "letsencrypt",
      "traefik.http.services.#{router}.loadbalancer.server.port" => to_string(port)
    }

    Map.merge(base, exposure_middleware_labels(router, exposure))
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
