defmodule Homelab.Networking do
  @moduledoc """
  Context for managing domains, DNS zones, and DNS records.
  """

  import Ecto.Query
  require Logger
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

  @doc """
  Edits an existing zone. Uses `DnsZone.update_changeset/2`, which holds `name`
  immutable — the records and domains scoped to this zone all hang off that name.
  """
  def update_dns_zone(%DnsZone{} = zone, attrs) do
    zone
    |> DnsZone.update_changeset(attrs)
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
  Ensures an A record for a system-level FQDN (not tied to a deployment), e.g.
  the self-hosted registry hostnames. Reuses the same zone/record upsert +
  provider push as deployment records, with a nil `deployment_id`.
  """
  def ensure_system_dns_record(fqdn, ip_config \\ %{}) when is_binary(fqdn) do
    zone_name = extract_zone_name(fqdn)

    case get_or_create_zone(zone_name) do
      {:ok, zone} ->
        record_name = extract_record_name(fqdn, zone_name)

        results =
          [
            {Map.get(ip_config, :public_ip), :public},
            {Map.get(ip_config, :internal_ip), :internal}
          ]
          |> Enum.filter(fn {ip, _scope} -> is_binary(ip) and ip != "" end)
          |> Enum.map(fn {ip, scope} ->
            upsert_dns_record(zone, %{
              name: record_name,
              type: "A",
              value: ip,
              scope: scope,
              managed: true,
              deployment_id: nil,
              dns_zone_id: zone.id
            })
          end)

        {:ok, results}

      {:error, reason} ->
        {:error, reason}
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

      payload = %{
        name: record.name,
        type: record.type,
        value: record.value,
        ttl: record.ttl
      }

      result =
        case find_provider_record(provider, zone_ref, record, zone) do
          {:ok, %{id: existing_id}} -> provider.update_record(zone_ref, existing_id, payload)
          :not_found -> provider.create_record(zone_ref, payload)
          {:error, _} -> fallback_create(provider, zone_ref, payload, record)
        end

      case result do
        {:ok, %{id: provider_record_id}} when not is_nil(provider_record_id) ->
          update_dns_record(record, %{provider_record_id: provider_record_id})

        {:error, {:api_error, 404, _}} when not is_nil(record.provider_record_id) ->
          # Stored id is stale (record removed at the provider) — retry as a create.
          case provider.create_record(zone_ref, payload) do
            {:ok, %{id: new_id}} when not is_nil(new_id) ->
              update_dns_record(record, %{provider_record_id: new_id})

            _ ->
              :ok
          end

        _ ->
          :ok
      end
    end)
  end

  # Resolves the provider-side record to update, if any. A stored
  # `provider_record_id` short-circuits the (potentially paginated) list call;
  # otherwise we read the provider's records and match on name+type so we update
  # a pre-existing record instead of blindly creating a duplicate over an FQDN
  # the user already manages.
  defp find_provider_record(_provider, _zone_ref, %DnsRecord{provider_record_id: id}, _zone)
       when is_binary(id) and id != "",
       do: {:ok, %{id: id}}

  defp find_provider_record(provider, zone_ref, record, zone) do
    case provider.list_records(zone_ref) do
      {:ok, records} ->
        wanted = candidate_names(record.name, zone && zone.name)

        match =
          Enum.find(records, fn r ->
            name_in?(r[:name] || r["name"], wanted) and
              type_matches?(r[:type] || r["type"], record.type)
          end)

        case match do
          nil -> :not_found
          %{} = r -> {:ok, %{id: r[:id] || r["id"]}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A record's name is stored relative to its zone ("www", "@"), but providers
  # return FQDNs. Build the set of names a provider record could carry.
  defp candidate_names(name, zone_name) do
    normalized_zone = zone_name && normalize_name(zone_name)

    fqdn =
      cond do
        is_nil(normalized_zone) -> nil
        name in ["@", "", nil] -> normalized_zone
        true -> "#{normalize_name(name)}.#{normalized_zone}"
      end

    [normalize_name(name), fqdn]
    |> Enum.reject(&is_nil/1)
    |> MapSet.new()
  end

  defp name_in?(nil, _wanted), do: false
  defp name_in?(provider_name, wanted), do: MapSet.member?(wanted, normalize_name(provider_name))

  defp normalize_name(nil), do: nil

  defp normalize_name(name),
    do: name |> to_string() |> String.downcase() |> String.trim_trailing(".")

  defp fallback_create(provider, zone_ref, payload, record) do
    Logger.warning(
      "DNS read-back failed for #{record.name}/#{record.type}; creating without dedup check"
    )

    provider.create_record(zone_ref, payload)
  end

  defp type_matches?(nil, _wanted), do: false
  defp type_matches?(a, b), do: String.upcase(to_string(a)) == String.upcase(to_string(b))

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
