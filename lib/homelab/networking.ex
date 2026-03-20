defmodule Homelab.Networking do
  @moduledoc """
  Context for managing domains, DNS zones, and DNS records.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Networking.{Domain, DnsZone, DnsRecord}

  # --- Domains ---

  def list_domains do
    Domain
    |> preload(deployment: [:tenant, :app_template])
    |> preload(:dns_zone)
    |> Repo.all()
  end

  def list_domains_for_deployment(deployment_id) do
    Domain
    |> where(deployment_id: ^deployment_id)
    |> Repo.all()
  end

  def list_expiring_tls(before_date) do
    Domain
    |> where([d], d.tls_status == :active)
    |> where([d], d.tls_expires_at <= ^before_date)
    |> preload(:deployment)
    |> Repo.all()
  end

  def list_pending_tls do
    Domain
    |> where([d], d.tls_status == :pending)
    |> preload(:deployment)
    |> Repo.all()
  end

  def get_domain(id) do
    case Repo.get(Domain, id) |> Repo.preload(:deployment) do
      nil -> {:error, :not_found}
      domain -> {:ok, domain}
    end
  end

  def get_domain!(id) do
    Repo.get!(Domain, id) |> Repo.preload(:deployment)
  end

  def get_domain_by_fqdn(fqdn) do
    case Repo.get_by(Domain, fqdn: fqdn) |> Repo.preload(:deployment) do
      nil -> {:error, :not_found}
      domain -> {:ok, domain}
    end
  end

  def create_domain(attrs) do
    %Domain{}
    |> Domain.changeset(attrs)
    |> Repo.insert()
  end

  def update_domain(%Domain{} = domain, attrs) do
    domain
    |> Domain.changeset(attrs)
    |> Repo.update()
  end

  def delete_domain(%Domain{} = domain) do
    Repo.delete(domain)
  end

  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

  # --- DNS Zones ---

  def list_dns_zones do
    DnsZone
    |> order_by(:name)
    |> Repo.all()
    |> Repo.preload(:dns_records)
  end

  def get_dns_zone(id) do
    case Repo.get(DnsZone, id) do
      nil -> {:error, :not_found}
      zone -> {:ok, Repo.preload(zone, :dns_records)}
    end
  end

  def get_dns_zone!(id) do
    Repo.get!(DnsZone, id) |> Repo.preload(:dns_records)
  end

  def get_dns_zone_by_name(name) do
    case Repo.get_by(DnsZone, name: name) do
      nil -> {:error, :not_found}
      zone -> {:ok, Repo.preload(zone, :dns_records)}
    end
  end

  def create_dns_zone(attrs) do
    %DnsZone{}
    |> DnsZone.changeset(attrs)
    |> Repo.insert()
  end

  def update_dns_zone(%DnsZone{} = zone, attrs) do
    zone
    |> DnsZone.changeset(attrs)
    |> Repo.update()
  end

  def delete_dns_zone(%DnsZone{} = zone) do
    Repo.delete(zone)
  end

  def change_dns_zone(%DnsZone{} = zone, attrs \\ %{}) do
    DnsZone.changeset(zone, attrs)
  end

  @doc """
  Syncs the zone list from the configured registrar provider.
  Creates new zones and updates existing ones with provider metadata.
  """
  def sync_zones_from_registrar do
    registrar = Homelab.Config.registrar()

    if registrar do
      case registrar.list_domains() do
        {:ok, domains} ->
          results =
            Enum.map(domains, fn d ->
              upsert_zone(%{
                name: d.name,
                provider: registrar.driver_id(),
                provider_zone_id: d.provider_zone_id,
                sync_status: :synced,
                last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
              })
            end)

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:error, :no_registrar_configured}
    end
  end

  defp upsert_zone(attrs) do
    case get_dns_zone_by_name(attrs.name) do
      {:ok, existing} ->
        update_dns_zone(existing, attrs)

      {:error, :not_found} ->
        create_dns_zone(attrs)
    end
  end

  # --- DNS Records ---

  def list_dns_records_for_zone(zone_id) do
    DnsRecord
    |> where(dns_zone_id: ^zone_id)
    |> order_by([:type, :name])
    |> preload(:deployment)
    |> Repo.all()
  end

  def list_dns_records_for_deployment(deployment_id) do
    DnsRecord
    |> where(deployment_id: ^deployment_id)
    |> preload(:dns_zone)
    |> Repo.all()
  end

  def get_dns_record(id) do
    case Repo.get(DnsRecord, id) do
      nil -> {:error, :not_found}
      record -> {:ok, Repo.preload(record, [:dns_zone, :deployment])}
    end
  end

  def get_dns_record!(id) do
    Repo.get!(DnsRecord, id) |> Repo.preload([:dns_zone, :deployment])
  end

  def create_dns_record(attrs) do
    %DnsRecord{}
    |> DnsRecord.changeset(attrs)
    |> Repo.insert()
  end

  def update_dns_record(%DnsRecord{} = record, attrs) do
    record
    |> DnsRecord.changeset(attrs)
    |> Repo.update()
  end

  def delete_dns_record(%DnsRecord{} = record) do
    Repo.delete(record)
  end

  def change_dns_record(%DnsRecord{} = record, attrs \\ %{}) do
    DnsRecord.changeset(record, attrs)
  end

  @doc """
  Ensures DNS records exist for a deployment's domain across all
  configured DNS providers (public + internal).
  """
  def ensure_deployment_dns_records(deployment, ip_config \\ %{}) do
    domain = deployment.domain

    if domain && domain != "" do
      zone_name = extract_zone_name(domain)

      case get_or_create_zone(zone_name) do
        {:ok, zone} ->
          public_ip = Map.get(ip_config, :public_ip)
          internal_ip = Map.get(ip_config, :internal_ip)
          record_name = extract_record_name(domain, zone_name)

          results = []

          results =
            if public_ip do
              result =
                upsert_dns_record(zone, %{
                  name: record_name,
                  type: "A",
                  value: public_ip,
                  scope: :public,
                  managed: true,
                  deployment_id: deployment.id,
                  dns_zone_id: zone.id
                })

              [result | results]
            else
              results
            end

          results =
            if internal_ip do
              result =
                upsert_dns_record(zone, %{
                  name: record_name,
                  type: "A",
                  value: internal_ip,
                  scope: :internal,
                  managed: true,
                  deployment_id: deployment.id,
                  dns_zone_id: zone.id
                })

              [result | results]
            else
              results
            end

          {:ok, results}

        {:error, reason} ->
          {:error, reason}
      end
    else
      {:ok, []}
    end
  end

  @doc """
  Removes all managed DNS records for a deployment and pushes
  deletions to the configured providers.
  """
  def cleanup_deployment_dns_records(deployment_id) do
    records = list_dns_records_for_deployment(deployment_id)
    managed = Enum.filter(records, & &1.managed)

    Enum.each(managed, fn record ->
      push_record_deletion(record)
      delete_dns_record(record)
    end)

    :ok
  end

  @doc """
  Pushes a DNS record to the appropriate external provider based on scope.
  """
  def push_record_to_provider(%DnsRecord{} = record) do
    record = Repo.preload(record, :dns_zone)
    zone = record.dns_zone

    providers = providers_for_scope(record.scope)

    Enum.each(providers, fn provider ->
      zone_ref = zone.provider_zone_id || zone.name

      case provider.create_record(zone_ref, %{
             name: record.name,
             type: record.type,
             value: record.value,
             ttl: record.ttl
           }) do
        {:ok, result} ->
          if provider_record_id = result[:id] do
            update_dns_record(record, %{provider_record_id: provider_record_id})
          end

        {:error, _reason} ->
          :ok
      end
    end)
  end

  defp push_record_deletion(%DnsRecord{} = record) do
    record = Repo.preload(record, :dns_zone)
    zone = record.dns_zone
    providers = providers_for_scope(record.scope)

    if record.provider_record_id do
      zone_ref = zone.provider_zone_id || zone.name

      Enum.each(providers, fn provider ->
        provider.delete_record(zone_ref, record.provider_record_id)
      end)
    end
  end

  defp providers_for_scope(:public) do
    case Homelab.Config.public_dns_provider() do
      nil -> []
      provider -> [provider]
    end
  end

  defp providers_for_scope(:internal) do
    case Homelab.Config.internal_dns_provider() do
      nil -> []
      provider -> [provider]
    end
  end

  defp providers_for_scope(:both) do
    providers_for_scope(:public) ++ providers_for_scope(:internal)
  end

  defp get_or_create_zone(zone_name) do
    case get_dns_zone_by_name(zone_name) do
      {:ok, zone} -> {:ok, zone}
      {:error, :not_found} -> create_dns_zone(%{name: zone_name, provider: "manual"})
    end
  end

  defp upsert_dns_record(zone, attrs) do
    existing =
      DnsRecord
      |> where(dns_zone_id: ^zone.id)
      |> where(name: ^attrs.name)
      |> where(type: ^attrs.type)
      |> where(scope: ^attrs.scope)
      |> Repo.one()

    case existing do
      nil ->
        case create_dns_record(attrs) do
          {:ok, record} ->
            push_record_to_provider(record)
            {:ok, record}

          error ->
            error
        end

      record ->
        case update_dns_record(record, attrs) do
          {:ok, record} ->
            push_record_to_provider(record)
            {:ok, record}

          error ->
            error
        end
    end
  end

  defp extract_zone_name(fqdn) do
    parts = String.split(fqdn, ".")

    if length(parts) > 2 do
      parts |> Enum.take(-2) |> Enum.join(".")
    else
      fqdn
    end
  end

  defp extract_record_name(fqdn, zone_name) do
    case String.trim_trailing(fqdn, ".#{zone_name}") do
      ^fqdn -> "@"
      name -> name
    end
  end
end
