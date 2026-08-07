defmodule Homelab.Config do
  @moduledoc """
  Centralized access to pluggable driver modules and platform settings.

  Each driver category has a configured list of available modules. Drivers
  describe themselves via `driver_id/0`, `display_name/0`, and `description/0`
  callbacks, so no hardcoded maps are needed.

  The active driver for single-choice categories (orchestrator, gateway, etc.)
  is stored in `Homelab.Settings` and resolved by `driver_id` at runtime.
  Application env overrides take precedence (useful for tests via Mox).
  """

  # -- Single-choice drivers (one active at a time) --

  @orchestrators [
    Homelab.Orchestrators.DockerEngine,
    Homelab.Orchestrators.DockerSwarm
  ]

  @gateways [
    Homelab.Gateways.Traefik
  ]

  @backup_providers [
    Homelab.BackupProviders.Restic
  ]

  @identity_brokers [
    Homelab.IdentityBrokers.GenericOidc
  ]

  @registrars [
    Homelab.Registrars.Cloudflare,
    Homelab.Registrars.Namecheap
  ]

  @dns_providers [
    Homelab.DnsProviders.Cloudflare,
    Homelab.DnsProviders.Unifi,
    Homelab.DnsProviders.Pihole
  ]

  @doc """
  The active orchestrator: an application-env override (tests), else the operator's
  choice in Settings, else one inferred from the daemon.

  Never `nil` — every deploy path depends on it, so a host with no recorded selection
  yet (first boot, before `Bootstrap.backfill_orchestrator/0` runs) falls back to what
  the daemon actually is rather than to a constant. Guessing "Docker Engine" on a
  Swarm host would treat its running services as absent.
  """
  def orchestrator, do: active_driver(:orchestrator, @orchestrators) || inferred_orchestrator()

  def gateway, do: active_driver(:gateway, @gateways)
  def backup_provider, do: active_driver(:backup_provider, @backup_providers)
  def identity_broker, do: active_driver(:identity_broker, @identity_brokers)
  def registrar, do: active_driver(:registrar, @registrars)
  def public_dns_provider, do: active_driver(:public_dns_provider, @dns_providers)
  def internal_dns_provider, do: active_driver(:internal_dns_provider, @dns_providers)

  def orchestrators, do: available_drivers(:orchestrators, @orchestrators)
  def gateways, do: available_drivers(:gateways, @gateways)
  def backup_providers, do: available_drivers(:backup_providers, @backup_providers)
  def identity_brokers, do: available_drivers(:identity_brokers, @identity_brokers)
  def registrars, do: available_drivers(:registrars, @registrars)
  def dns_providers, do: available_drivers(:dns_providers, @dns_providers)

  # -- Multi-choice drivers (all enabled simultaneously) --

  @registries [
    Homelab.Registries.DockerHub,
    Homelab.Registries.GHCR,
    Homelab.Registries.ECR
  ]

  # Every available catalog source. None is a "wall of apps" by default — the
  # user opts in per source from Settings → Catalog. `os_bases` (base OS images
  # for the Workbench) is enabled by default; the four community catalogs are
  # opt-in but never removed.
  @application_catalogs [
    Homelab.Catalogs.OsBases,
    Homelab.Catalogs.Curated,
    Homelab.Catalogs.LinuxServer,
    Homelab.Catalogs.Hotio,
    Homelab.Catalogs.AwesomeSelfhosted
  ]

  @default_enabled_catalogs ["os_bases"]

  def registries, do: available_drivers(:registries, @registries)

  @doc "Every catalog source module, regardless of enabled state (for the settings UI)."
  def all_application_catalogs,
    do: Application.get_env(:homelab, :application_catalogs, @application_catalogs)

  @doc """
  The currently-enabled catalog source modules. An `:application_catalogs` app-env
  override (used by tests) wins; otherwise the enabled set comes from the
  `enabled_catalogs` setting (a JSON list of driver_ids), defaulting to os_bases.
  """
  def application_catalogs do
    case Application.get_env(:homelab, :application_catalogs) do
      nil ->
        enabled = enabled_catalog_ids()
        Enum.filter(@application_catalogs, &(&1.driver_id() in enabled))

      override ->
        override
    end
  end

  defp enabled_catalog_ids do
    case Homelab.Settings.get("enabled_catalogs") do
      nil ->
        @default_enabled_catalogs

      json when is_binary(json) ->
        case Jason.decode(json) do
          {:ok, ids} when is_list(ids) -> ids
          _ -> @default_enabled_catalogs
        end
    end
  end

  # -- Registry availability for image refs --

  @doc """
  Determines the registry driver_id for a given image reference.
  Used to check if the registry hosting an image is available.
  """
  def registry_for_image(nil), do: "dockerhub"
  def registry_for_image(""), do: "dockerhub"

  def registry_for_image(full_ref) do
    cond do
      String.starts_with?(full_ref, registry_ref_prefix() <> "/") -> "self_hosted"
      String.starts_with?(full_ref, "ghcr.io/") -> "ghcr"
      String.starts_with?(full_ref, "public.ecr.aws/") -> "ecr"
      String.starts_with?(full_ref, "lscr.io/") -> "dockerhub"
      String.starts_with?(full_ref, "docker.io/") -> "dockerhub"
      true -> "dockerhub"
    end
  end

  @doc """
  Returns true if the registry for a given image ref is available
  (either always-public or explicitly configured with credentials).
  """
  def image_pullable?(full_ref) do
    registry_id = registry_for_image(full_ref)

    if registry_id == "self_hosted" do
      registry_configured?()
    else
      pullable_external?(registry_id)
    end
  end

  defp pullable_external?(registry_id) do
    case Enum.find(registries(), fn mod ->
           function_exported?(mod, :driver_id, 0) and mod.driver_id() == registry_id
         end) do
      nil ->
        registry_id == "dockerhub"

      mod ->
        if function_exported?(mod, :configured?, 0) do
          mod.configured?()
        else
          true
        end
    end
  end

  @doc """
  Returns a list of registry driver_ids that are currently available for pulling.
  """
  def available_registry_ids do
    always_available = ["dockerhub"]

    configured =
      registries()
      |> Enum.filter(fn mod ->
        Code.ensure_loaded?(mod) and
          if(function_exported?(mod, :configured?, 0), do: mod.configured?(), else: true)
      end)
      |> Enum.map(fn mod -> mod.driver_id() end)

    Enum.uniq(always_available ++ configured)
  end

  # -- Other settings --

  def base_domain do
    # Precedence mirrors the driver settings above: an explicit app-env override
    # (set from HOMELAB_BASE_DOMAIN in runtime.exs) wins, then the operator's
    # `base_domain` Setting (from the setup wizard / Settings UI), then the
    # placeholder default. Previously this read ONLY the app-env, which nothing
    # set — so it was permanently "homelab.local" regardless of configuration,
    # breaking every deployment domain, the registry, and the self-ingress route.
    Application.get_env(:homelab, :base_domain) ||
      Homelab.Settings.get("base_domain") ||
      "homelab.local"
  end

  @doc """
  The parent domains a wildcard certificate is held for, most specific first.

  `base_domain` is always in the list: `Infrastructure.self_ingress_yaml/2` provisions
  `*.<base_domain>` unconditionally, so that wildcard exists whether or not anyone
  configured it, and a router under it should reuse it rather than order its own cert.

  Additional parents come from the `wildcard_domains` Setting. They are not free —
  Traefik will attempt a DNS-01 challenge for each one a route actually matches, which
  needs the plane's DNS token to have authority over that zone. Listing a parent is the
  operator asserting it does.

  Sorted longest-first so the list reads most-specific-first for a human. Callers do not
  depend on the order: coverage is an exact one-label test, so at most one parent can
  match any given host.

  Read through `get_cached/2` rather than `get/1`. `SpecBuilder` builds labels on paths
  with no database checked out — the same trap that took 38 specs down when
  `forward_auth_address/0` first read straight through.
  """
  def wildcard_domains do
    configured =
      "wildcard_domains"
      |> Homelab.Settings.get_cached("")
      |> to_string()
      |> String.split([",", "\n"], trim: true)
      |> Enum.map(&(&1 |> String.trim() |> String.trim_leading("*.")))
      |> Enum.reject(&(&1 == ""))

    [base_domain() | configured]
    |> Enum.uniq()
    |> Enum.sort_by(&byte_size/1, :desc)
  end

  # The address Traefik's forwardAuth middleware calls to authorize a request on a
  # `:sso_protected` route. Authentik's outpost shape, because that is what this
  # default has always been.
  @default_forward_auth_address "http://authentik-proxy:9000/outpost.goauthentik.io/auth/nginx"

  @doc """
  The forward-auth endpoint for `:sso_protected` routes.

  This was hardcoded in TWO places — `SpecBuilder.exposure_middleware_labels/2` (the
  Docker-label path that production actually uses) and `Gateways.Traefik.build_middlewares/2`
  (the file-provider path) — naming a host, `authentik-proxy`, that this application
  never provisions and gave the operator no way to change. Deployed workloads are named
  `homelab_<tenant>_<app>`, so nothing deployed here could ever answer to it.

  Making it a Setting does not make SSO work; it makes it *possible* to point at
  something that does. Traefik fails closed on an unreachable forwardAuth backend
  (500, not open), so a wrong or unset value is an availability problem, not an
  exposure one.

  The default is the historical hardcoded value, so behaviour is unchanged until an
  operator sets the `forward_auth_address` Setting.

  Reads through `get_cached/2`, not `get/2`: `SpecBuilder.build/1` runs on every deploy
  and is exercised by no-DB unit tests, so a Repo call here turns a pure label-building
  function into one that needs a sandbox connection. `Settings.set/3` and `delete/1`
  both maintain the ETS entry, so the cached read is authoritative.
  """
  def forward_auth_address do
    case Homelab.Settings.get_cached("forward_auth_address") do
      value when is_binary(value) ->
        case String.trim(value) do
          "" -> @default_forward_auth_address
          trimmed -> trimmed
        end

      _ ->
        @default_forward_auth_address
    end
  end

  @doc "The default forward-auth endpoint, shown as the placeholder in Settings."
  def default_forward_auth_address, do: @default_forward_auth_address

  # -- Self-hosted registry --

  @doc """
  The hostname prefix for images stored in the self-hosted registry, e.g.
  `"registry.example.com"`. Deploy specs reference images under this prefix.
  """
  def registry_ref_prefix, do: "registry.#{base_domain()}"

  @doc "The hostname of the pull-through Docker Hub mirror."
  def registry_mirror_host, do: "proxy-registry.#{base_domain()}"

  @doc """
  Whether the self-hosted registry is enabled and has push/pull credentials.

  An `:registry_enabled` application-env override takes precedence (test seam).
  """
  def registry_configured? do
    enabled? =
      case Application.get_env(:homelab, :registry_enabled) do
        nil -> Homelab.Settings.get("registry_enabled") == "true"
        override -> override == true or override == "true"
      end

    enabled? and match?({u, p} when is_binary(u) and is_binary(p), registry_credentials())
  end

  @doc """
  The registry push/pull credentials as `{username, password}`, or `nil` when
  either is unset. An `:registry_credentials` application-env override takes
  precedence (test seam).
  """
  def registry_credentials do
    case Application.get_env(:homelab, :registry_credentials) do
      {u, p} when is_binary(u) and is_binary(p) ->
        {u, p}

      _ ->
        username = Homelab.Settings.get("registry_username")
        password = Homelab.Settings.get("registry_password")

        if is_binary(username) and username != "" and is_binary(password) and password != "" do
          {username, password}
        else
          nil
        end
    end
  end

  def tenant_setting(tenant, key, default \\ nil) do
    Map.get(tenant.settings || %{}, key, platform_default(key, default))
  end

  # -- Driver resolution --

  defp active_driver(category, defaults) do
    case Application.get_env(:homelab, category) do
      nil ->
        modules = available_drivers(category, defaults)
        setting_key = Atom.to_string(category)

        case Homelab.Settings.get(setting_key) do
          nil ->
            nil

          selected_id ->
            # `Code.ensure_loaded?/1` first: in a release, modules load lazily, and
            # `function_exported?/3` reports FALSE for a module that simply has not been
            # loaded yet. Without this, a driver the operator selected in Settings can
            # silently fail to resolve — the selection looks ignored.
            Enum.find(modules, fn mod ->
              Code.ensure_loaded?(mod) and function_exported?(mod, :driver_id, 0) and
                mod.driver_id() == selected_id
            end)
        end

      module ->
        module
    end
  end

  # `category` is the plural key for a driver catalogue (a list), but `active_driver/2`
  # also passes the SINGULAR key, which may hold a single module override — or an
  # explicit nil. Only a real list overrides the defaults; anything else leaves the
  # catalogue intact, so we never hand `Enum.find/2` a module or a nil.
  defp available_drivers(category, defaults) do
    case Application.get_env(:homelab, category) do
      list when is_list(list) -> list
      _ -> defaults
    end
  end

  @doc "Clears the inferred-orchestrator memo (for tests/ops)."
  def reset_inferred_orchestrator do
    :persistent_term.erase({__MODULE__, :inferred_orchestrator})
    :ok
  end

  # Memoized: this is a boot-time gap (no selection recorded yet), and `orchestrator/0`
  # is called per-deployment on hot paths — it must not hit the daemon every time. Once
  # a selection exists in Settings it wins outright, so leaving Swarm never needs this
  # cache invalidated.
  defp inferred_orchestrator do
    case :persistent_term.get({__MODULE__, :inferred_orchestrator}, nil) do
      nil ->
        # Manager, not merely "in a swarm": a WORKER reports LocalNodeState "active"
        # but has no control plane, so choosing DockerSwarm there would fail every
        # deploy with "This node is not a swarm manager".
        module =
          if Homelab.Docker.Network.swarm_manager?(),
            do: Homelab.Orchestrators.DockerSwarm,
            else: Homelab.Orchestrators.DockerEngine

        :persistent_term.put({__MODULE__, :inferred_orchestrator}, module)
        module

      module ->
        module
    end
  end

  defp platform_default("max_apps", default), do: default || 5
  defp platform_default("max_memory_mb", default), do: default || 2048
  defp platform_default("backup_retention_days", default), do: default || 30
  defp platform_default(_, default), do: default
end
