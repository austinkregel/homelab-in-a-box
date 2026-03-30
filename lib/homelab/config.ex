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

  @application_catalogs [
    Homelab.Catalogs.Curated
  ]

  def registries, do: available_drivers(:registries, @registries)
  def application_catalogs, do: available_drivers(:application_catalogs, @application_catalogs)

  # -- Registry availability for image refs --

  @doc """
  Determines the registry driver_id for a given image reference.
  Used to check if the registry hosting an image is available.
  """
  def registry_for_image(nil), do: "dockerhub"
  def registry_for_image(""), do: "dockerhub"

  def registry_for_image(full_ref) do
    cond do
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
