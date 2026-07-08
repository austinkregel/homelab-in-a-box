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

  def orchestrator, do: active_driver(:orchestrator, @orchestrators)
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
  def all_application_catalogs, do: Application.get_env(:homelab, :application_catalogs, @application_catalogs)

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
    Application.get_env(:homelab, :base_domain, "homelab.local")
  end

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
            Enum.find(modules, fn mod ->
              function_exported?(mod, :driver_id, 0) and mod.driver_id() == selected_id
            end)
        end

      module ->
        module
    end
  end

  defp available_drivers(category, defaults) do
    Application.get_env(:homelab, category, defaults)
  end

  defp platform_default("max_apps", default), do: default || 5
  defp platform_default("max_memory_mb", default), do: default || 2048
  defp platform_default("backup_retention_days", default), do: default || 30
  defp platform_default(_, default), do: default
end
