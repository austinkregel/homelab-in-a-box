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

  @doc """
  Every record row that already resolves `fqdn`, whoever wrote it.

  Deliberately NOT scoped to a deployment. The question this answers is "which of these
  rows did I not write", and the rows a caller did not write are precisely the ones
  belonging to another deployment, to an earlier release, or to nobody — so scoping by
  `deployment_id` would return an empty answer for the cases that matter.

  Decomposed into zone + record name the same way `ensure_deployment_dns_records/2`
  does, so a caller asking this before an upsert sees exactly the rows that upsert is
  about to take over.
  """
  def list_dns_records_for_fqdn(fqdn) when is_binary(fqdn) do
    zone_name = extract_zone_name(fqdn)
    record_name = extract_record_name(fqdn, zone_name)

    DnsRecord
    |> join(:inner, [r], z in assoc(r, :dns_zone))
    |> where([r, z], z.name == ^zone_name and r.name == ^record_name)
    |> preload(:dns_zone)
    |> Repo.all()
  end

  def list_dns_records_for_fqdn(_fqdn), do: []

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
  Ensures DNS records exist for every hostname a deployment answers on, across all
  configured DNS providers (public + internal).

  That is the primary `domain` AND each host in `additional_domains`. Aliases used to be
  skipped, which made a host alias only half a route: Traefik would match
  `matrix.example.com` and Let's Encrypt would issue for it, but nothing resolved the
  name, so it was reachable only for whoever had already put the record in by hand. The
  routing layer and the DNS layer disagreeing about which names exist is exactly the
  class of bug that only shows up from the outside.

  Each host is resolved to its own zone rather than the primary's, so an alias on a
  different apex lands in the right place. A host that fails is reported without stopping
  the others — a bad alias must not cost the primary domain its record.

  ## The return shape, and why a partial write is `{:ok, _}`

  Returns `{:ok, results}` where `results` is a flat list of per-record `{:ok, record}`
  and `{:error, reason}` tuples — a host whose ZONE could not be resolved contributes one
  error entry per address it would have written, so a caller sees every failure in the
  same shape whatever layer it happened at.

  A partial write is `{:ok, _}` on purpose, even though the caller will treat it as a
  failed step. `PublishDns` can only undo records whose ids it was told about, and
  collapsing to a bare `{:error, reason}` threw away the ids of everything that HAD been
  written: the primary's record was live, the step failed, and compensation saw nothing
  to delete. On the retry those rows read as pre-existing and land in `took_over`, so
  they stay permanently outside the step's ownership — an A record pointing at a
  container nobody will ever clean up. The rule is that this function never reports a
  failure in a way that loses a durable side effect.

  `{:error, reasons}` is therefore reserved for "nothing was written DESPITE being asked
  to", where there is nothing to lose. It carries EVERY reason, not just the first.

  "Nothing was ASKED for" is a different answer and is `{:ok, []}`. `detect_ip_config/0`
  returns both addresses as `nil` whenever `get_host_lan_ip/0` finds no non-loopback IPv4
  — a loopback-only or IPv6-only host, or `:inet.getifaddrs/0` erroring — and on such a
  host there is no address to publish and nothing has gone wrong. Conflating the two
  failed those deploys outright with an empty reason list, which is its own tell: nothing
  failed, so nothing had a reason.
  """
  def ensure_deployment_dns_records(deployment, ip_config \\ %{}) do
    case deployment_hostnames(deployment) do
      [] ->
        {:ok, []}

      hosts ->
        results = Enum.flat_map(hosts, &ensure_host_dns_records(deployment, &1, ip_config))

        # `results == []` means no ADDRESS was requested, not that every write failed --
        # see the moduledoc. It is the ordinary state of a host with no routable IPv4,
        # and it must stay the no-op it has always been rather than failing the release.
        if results == [] or Enum.any?(results, &match?({:ok, _}, &1)) do
          {:ok, results}
        else
          {:error, Enum.map(results, fn {:error, reason} -> reason end)}
        end
    end
  end

  @doc """
  Every hostname a deployment answers on: the primary `domain` first, then each
  `additional_domains` host, deduped.

  Public because `PublishDns` has to scope its rollback to exactly the records it
  created, and it can only do that by reading which names it is about to publish BEFORE
  publishing them. Deriving that list separately there is how the two would drift into
  disagreeing about which names a deployment owns.

  An alias is a host the deployment ANSWERS on; a `path_prefix` on it scopes which
  requests that host serves and has no bearing on whether the name has to resolve, so
  path-scoped aliases are included like any other.
  """
  @spec deployment_hostnames(map()) :: [String.t()]
  def deployment_hostnames(deployment) do
    aliases =
      deployment
      |> Map.get(:additional_domains)
      |> List.wrap()
      |> Enum.map(& &1["host"])

    [deployment.domain | aliases]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.uniq()
  end

  # One flat list of per-record results for a single host. A zone failure is reported as
  # one error PER ADDRESS this host would have written rather than a single host-level
  # error, so the caller's accounting ("how many records did this step write, and how
  # many did it fail to?") stays a straight count over one list.
  defp ensure_host_dns_records(deployment, host, ip_config) do
    zone_name = extract_zone_name(host)
    addresses = requested_addresses(ip_config)

    case get_or_create_zone(zone_name) do
      {:ok, zone} ->
        record_name = extract_record_name(host, zone_name)

        Enum.map(addresses, fn {scope, ip} ->
          upsert_dns_record(zone, %{
            name: record_name,
            type: "A",
            value: ip,
            scope: scope,
            managed: true,
            deployment_id: deployment.id,
            dns_zone_id: zone.id
          })
        end)

      {:error, reason} ->
        Enum.map(addresses, fn _address -> {:error, reason} end)
    end
  end

  defp requested_addresses(ip_config) do
    [public: Map.get(ip_config, :public_ip), internal: Map.get(ip_config, :internal_ip)]
    |> Enum.filter(fn {_scope, ip} -> ip end)
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
  Removes all managed DNS records for a deployment and pushes deletions to the
  configured providers.

  Returns `:ok`, or `{:error, {:dns_deletion_failed, [{record_id, reason}]}}` if any
  provider refused. See `delete_dns_records/1` for why the local rows of the refused
  records are kept.
  """
  def cleanup_deployment_dns_records(deployment_id) do
    deployment_id
    |> list_dns_records_for_deployment()
    |> Enum.filter(& &1.managed)
    |> delete_dns_records()
  end

  @doc """
  Removes exactly the managed records named by `record_ids`, and only those still
  belonging to `deployment_id`.

  The scoped counterpart of `cleanup_deployment_dns_records/1`, for a caller that has
  to undo the records IT wrote rather than every record a deployment holds — a release
  compensating its own `publish_dns` step, say. `managed: true` distinguishes
  homelab-written rows from operator-hand-made ones and says nothing about WHICH writer
  produced a row, so it cannot answer that question on its own.

  The `deployment_id` re-check is not redundant with the ids: between the write and the
  undo a record may legitimately have been re-pointed at another deployment, and that
  row is no longer the caller's to delete.

  Same return shape as `cleanup_deployment_dns_records/1`.
  """
  def delete_dns_records_for(record_ids, deployment_id) when is_list(record_ids) do
    DnsRecord
    |> where([r], r.id in ^record_ids and r.deployment_id == ^deployment_id and r.managed == true)
    |> preload(:dns_zone)
    |> Repo.all()
    |> delete_dns_records()
  end

  @doc """
  Deletes loaded `DnsRecord` rows, pushing each deletion to its provider FIRST.

  The order is the contract. Deleting the local row before (or regardless of) the
  provider push drops homelab's only record of a record that still exists at
  Cloudflare — an orphan nothing can ever clean up, because the `provider_record_id`
  that addresses it lived on the row just deleted. So a record whose provider push
  fails keeps its row, and the failure is RETURNED: a cleanup that could not reach the
  provider has not cleaned anything up, and a compensation built on it must not report
  success.

  Every record is attempted; one refusal does not abandon the rest.
  """
  def delete_dns_records(records) when is_list(records) do
    records
    |> Enum.reduce([], fn record, failures ->
      case push_record_deletion(record) do
        :ok ->
          delete_dns_record(record)
          failures

        {:error, reason} ->
          Logger.error(
            "DNS provider refused deletion of #{record.name}/#{record.type} " <>
              "(#{inspect(reason)}); keeping the local row so a retry can still reach it"
          )

          [{record.id, reason} | failures]
      end
    end)
    |> case do
      [] -> :ok
      failures -> {:error, {:dns_deletion_failed, Enum.reverse(failures)}}
    end
  end

  @doc """
  Pushes a DNS record to the appropriate external provider based on scope.
  """
  def push_record_to_provider(%DnsRecord{} = record) do
    record = Repo.preload(record, :dns_zone)
    zone = record.dns_zone

    case providers_for_scope(record.scope) do
      [] ->
        # No provider configured for this scope. The record exists locally and resolves
        # nowhere; saying so is the whole point.
        record_sync_failure(record, "no DNS provider is configured for the #{record.scope} scope")

      providers ->
        providers
        |> Enum.map(&push_to_one_provider(&1, record, zone))
        |> collect_sync_result(record)
    end
  end

  defp push_to_one_provider(provider, record, zone) do
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
        :ok

      {:error, {:api_error, 404, _}} when not is_nil(record.provider_record_id) ->
        # Stored id is stale (record removed at the provider) — retry as a create.
        case provider.create_record(zone_ref, payload) do
          {:ok, %{id: new_id}} when not is_nil(new_id) ->
            update_dns_record(record, %{provider_record_id: new_id})
            :ok

          {:error, reason} ->
            {:error, describe(provider, reason)}

          _ ->
            {:error, describe(provider, :no_record_id_returned)}
        end

      {:error, reason} ->
        {:error, describe(provider, reason)}

      _ ->
        {:error, describe(provider, :no_record_id_returned)}
    end
  end

  # Every failure here used to collapse to `:ok` — an `Enum.each` with three `-> :ok`
  # discards — so an expired token, a 403 or a wrong zone id all produced "DNS record
  # created!". Now the outcome is recorded ON the row and returned to the caller, so the
  # UI can say what happened and the failure survives a page reload.
  defp collect_sync_result(results, record) do
    case Enum.filter(results, &match?({:error, _}, &1)) do
      [] ->
        update_dns_record(record, %{
          last_synced_at: DateTime.utc_now() |> DateTime.truncate(:second),
          last_sync_error: nil
        })

        :ok

      errors ->
        record_sync_failure(record, Enum.map_join(errors, "; ", fn {:error, m} -> m end))
    end
  end

  defp record_sync_failure(record, message) do
    update_dns_record(record, %{last_sync_error: String.slice(message, 0, 500)})
    {:error, message}
  end

  defp describe(provider, reason) do
    name =
      provider
      |> Module.split()
      |> List.last()

    "#{name}: #{inspect(reason)}"
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

  # `:ok` or `{:error, reasons}`. Results used to be discarded by an `Enum.each`, which
  # is what let a refused deletion pass for a completed one.
  defp push_record_deletion(%DnsRecord{provider_record_id: nil}), do: :ok

  defp push_record_deletion(%DnsRecord{} = record) do
    record = Repo.preload(record, :dns_zone)

    case record.dns_zone do
      # No zone means no provider address for this record; there is nothing to push and
      # nothing to orphan.
      nil ->
        :ok

      zone ->
        zone_ref = zone.provider_zone_id || zone.name

        record.scope
        |> providers_for_scope()
        |> Enum.reduce([], fn provider, failures ->
          case provider.delete_record(zone_ref, record.provider_record_id) do
            :ok -> failures
            {:ok, _} -> failures
            {:error, reason} -> [reason | failures]
            other -> [other | failures]
          end
        end)
        |> case do
          [] -> :ok
          reasons -> {:error, Enum.reverse(reasons)}
        end
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
