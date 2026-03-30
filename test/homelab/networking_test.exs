defmodule Homelab.NetworkingTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Networking
  alias Homelab.Networking.{Domain, DnsZone, DnsRecord}

  setup :set_mox_global
  setup :verify_on_exit!

  # --- Domains ---

  describe "list_domains/0" do
    test "returns all domains with preloaded deployment" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment)

      domains = Networking.list_domains()
      assert length(domains) == 1
      assert hd(domains).deployment != nil
    end

    test "returns empty list when no domains exist" do
      assert Networking.list_domains() == []
    end
  end

  describe "list_domains_for_deployment/1" do
    test "returns domains for a specific deployment" do
      deployment = insert(:deployment)
      other_deployment = insert(:deployment)
      insert(:domain, deployment: deployment)
      insert(:domain, deployment: other_deployment)

      domains = Networking.list_domains_for_deployment(deployment.id)
      assert length(domains) == 1
      assert hd(domains).deployment_id == deployment.id
    end

    test "returns empty list when deployment has no domains" do
      deployment = insert(:deployment)
      assert Networking.list_domains_for_deployment(deployment.id) == []
    end
  end

  describe "list_expiring_tls/1" do
    test "returns domains with TLS expiring before given date" do
      deployment = insert(:deployment)
      expiring_date = DateTime.utc_now() |> DateTime.add(5, :day) |> DateTime.truncate(:second)
      far_date = DateTime.utc_now() |> DateTime.add(90, :day) |> DateTime.truncate(:second)
      check_before = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: expiring_date,
        fqdn: "expiring.homelab.local"
      )

      insert(:domain,
        deployment: deployment,
        tls_status: :active,
        tls_expires_at: far_date,
        fqdn: "not-expiring.homelab.local"
      )

      expiring = Networking.list_expiring_tls(check_before)
      assert length(expiring) == 1
      assert hd(expiring).fqdn == "expiring.homelab.local"
    end

    test "excludes domains with non-active TLS status" do
      deployment = insert(:deployment)
      soon = DateTime.utc_now() |> DateTime.add(5, :day) |> DateTime.truncate(:second)
      check_before = DateTime.utc_now() |> DateTime.add(30, :day) |> DateTime.truncate(:second)

      insert(:domain,
        deployment: deployment,
        tls_status: :pending,
        tls_expires_at: soon,
        fqdn: "pending-tls.homelab.local"
      )

      assert Networking.list_expiring_tls(check_before) == []
    end
  end

  describe "list_pending_tls/0" do
    test "returns domains with pending TLS" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment, tls_status: :pending, fqdn: "pending.homelab.local")
      insert(:domain, deployment: deployment, tls_status: :active, fqdn: "active.homelab.local")

      pending = Networking.list_pending_tls()
      assert length(pending) == 1
      assert hd(pending).fqdn == "pending.homelab.local"
    end
  end

  describe "get_domain/1" do
    test "returns domain by id" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)
      assert {:ok, found} = Networking.get_domain(domain.id)
      assert found.id == domain.id
      assert found.deployment != nil
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_domain(0)
    end
  end

  describe "get_domain_by_fqdn/1" do
    test "returns domain by fqdn" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment, fqdn: "app.homelab.local")

      assert {:ok, found} = Networking.get_domain_by_fqdn("app.homelab.local")
      assert found.fqdn == "app.homelab.local"
    end

    test "returns error when fqdn not found" do
      assert {:error, :not_found} = Networking.get_domain_by_fqdn("nonexistent.homelab.local")
    end
  end

  describe "create_domain/1" do
    test "creates a domain with valid attrs" do
      deployment = insert(:deployment)

      attrs = %{
        fqdn: "nextcloud.friends.homelab.local",
        deployment_id: deployment.id,
        exposure_mode: :sso_protected
      }

      assert {:ok, %Domain{} = domain} = Networking.create_domain(attrs)
      assert domain.fqdn == "nextcloud.friends.homelab.local"
      assert domain.tls_status == :pending
      assert domain.exposure_mode == :sso_protected
    end

    test "returns error with invalid fqdn" do
      deployment = insert(:deployment)
      attrs = %{fqdn: "INVALID DOMAIN!", deployment_id: deployment.id}
      assert {:error, changeset} = Networking.create_domain(attrs)
      assert errors_on(changeset).fqdn != []
    end

    test "enforces unique fqdn constraint" do
      deployment = insert(:deployment)
      insert(:domain, deployment: deployment, fqdn: "taken.homelab.local")

      attrs = %{fqdn: "taken.homelab.local", deployment_id: deployment.id}
      assert {:error, changeset} = Networking.create_domain(attrs)
      assert errors_on(changeset).fqdn != []
    end

    test "returns error when missing required fields" do
      assert {:error, changeset} = Networking.create_domain(%{})
      assert errors_on(changeset).fqdn != []
      assert errors_on(changeset).deployment_id != []
    end
  end

  describe "update_domain/2" do
    test "updates domain attributes" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)

      assert {:ok, updated} = Networking.update_domain(domain, %{tls_status: :active})
      assert updated.tls_status == :active
    end

    test "updates exposure_mode" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment, exposure_mode: :sso_protected)

      assert {:ok, updated} = Networking.update_domain(domain, %{exposure_mode: :public})
      assert updated.exposure_mode == :public
    end
  end

  describe "delete_domain/1" do
    test "deletes a domain" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)
      assert {:ok, _} = Networking.delete_domain(domain)
      assert {:error, :not_found} = Networking.get_domain(domain.id)
    end
  end

  # --- DNS Zones ---

  describe "list_dns_zones/0" do
    test "returns all zones ordered by name" do
      insert(:dns_zone, name: "bravo.example.com")
      insert(:dns_zone, name: "alpha.example.com")

      zones = Networking.list_dns_zones()
      assert length(zones) == 2
      names = Enum.map(zones, & &1.name)
      assert names == ["alpha.example.com", "bravo.example.com"]
    end

    test "preloads dns_records" do
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone)

      [loaded_zone] = Networking.list_dns_zones()
      assert length(loaded_zone.dns_records) == 1
    end

    test "returns empty list when no zones exist" do
      assert Networking.list_dns_zones() == []
    end
  end

  describe "get_dns_zone/1" do
    test "returns zone by id with dns_records preloaded" do
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone)

      assert {:ok, found} = Networking.get_dns_zone(zone.id)
      assert found.id == zone.id
      assert length(found.dns_records) == 1
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_dns_zone(0)
    end
  end

  describe "get_dns_zone!/1" do
    test "returns zone by id" do
      zone = insert(:dns_zone)
      found = Networking.get_dns_zone!(zone.id)
      assert found.id == zone.id
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Networking.get_dns_zone!(0)
      end
    end
  end

  describe "get_dns_zone_by_name/1" do
    test "returns zone by name" do
      insert(:dns_zone, name: "example.com")

      assert {:ok, found} = Networking.get_dns_zone_by_name("example.com")
      assert found.name == "example.com"
    end

    test "returns error when name not found" do
      assert {:error, :not_found} = Networking.get_dns_zone_by_name("nonexistent.com")
    end
  end

  describe "create_dns_zone/1" do
    test "creates a zone with valid attrs" do
      attrs = %{name: "myzone.example.com", provider: "cloudflare"}

      assert {:ok, %DnsZone{} = zone} = Networking.create_dns_zone(attrs)
      assert zone.name == "myzone.example.com"
      assert zone.provider == "cloudflare"
      assert zone.sync_status == :pending
    end

    test "creates a zone with default provider" do
      attrs = %{name: "manual.example.com"}
      assert {:ok, zone} = Networking.create_dns_zone(attrs)
      assert zone.provider == "manual"
    end

    test "returns error with invalid name" do
      attrs = %{name: "INVALID ZONE!"}
      assert {:error, changeset} = Networking.create_dns_zone(attrs)
      assert errors_on(changeset).name != []
    end

    test "enforces unique name constraint" do
      insert(:dns_zone, name: "unique.example.com")
      attrs = %{name: "unique.example.com"}
      assert {:error, changeset} = Networking.create_dns_zone(attrs)
      assert errors_on(changeset).name != []
    end

    test "returns error when name is missing" do
      assert {:error, changeset} = Networking.create_dns_zone(%{})
      assert errors_on(changeset).name != []
    end
  end

  describe "update_dns_zone/2" do
    test "updates zone attributes" do
      zone = insert(:dns_zone)

      assert {:ok, updated} =
               Networking.update_dns_zone(zone, %{
                 provider: "cloudflare",
                 sync_status: :synced
               })

      assert updated.provider == "cloudflare"
      assert updated.sync_status == :synced
    end
  end

  describe "delete_dns_zone/1" do
    test "deletes a zone" do
      zone = insert(:dns_zone)
      assert {:ok, _} = Networking.delete_dns_zone(zone)
      assert {:error, :not_found} = Networking.get_dns_zone(zone.id)
    end
  end

  # --- DNS Records ---

  describe "list_dns_records_for_zone/1" do
    test "returns records for a specific zone" do
      zone = insert(:dns_zone)
      other_zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, name: "www", type: "A")
      insert(:dns_record, dns_zone: other_zone, name: "mail", type: "A")

      records = Networking.list_dns_records_for_zone(zone.id)
      assert length(records) == 1
      assert hd(records).name == "www"
    end

    test "returns records ordered by type and name" do
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, name: "mail", type: "MX", value: "mail.example.com")
      insert(:dns_record, dns_zone: zone, name: "www", type: "A")
      insert(:dns_record, dns_zone: zone, name: "api", type: "A")

      records = Networking.list_dns_records_for_zone(zone.id)
      types_and_names = Enum.map(records, &{&1.type, &1.name})
      assert types_and_names == [{"A", "api"}, {"A", "www"}, {"MX", "mail"}]
    end

    test "returns empty list when zone has no records" do
      zone = insert(:dns_zone)
      assert Networking.list_dns_records_for_zone(zone.id) == []
    end
  end

  describe "list_dns_records_for_deployment/1" do
    test "returns records associated with a deployment" do
      deployment = insert(:deployment)
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, deployment: deployment, name: "app")

      records = Networking.list_dns_records_for_deployment(deployment.id)
      assert length(records) == 1
      assert hd(records).deployment_id == deployment.id
    end
  end

  describe "get_dns_record/1" do
    test "returns record by id with preloads" do
      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone)

      assert {:ok, found} = Networking.get_dns_record(record.id)
      assert found.id == record.id
      assert found.dns_zone != nil
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_dns_record(0)
    end
  end

  describe "get_dns_record!/1" do
    test "returns record by id" do
      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone)
      found = Networking.get_dns_record!(record.id)
      assert found.id == record.id
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Networking.get_dns_record!(0)
      end
    end
  end

  describe "create_dns_record/1" do
    test "creates a record with valid attrs" do
      zone = insert(:dns_zone)

      attrs = %{
        name: "www",
        type: "A",
        value: "192.168.1.100",
        dns_zone_id: zone.id
      }

      assert {:ok, %DnsRecord{} = record} = Networking.create_dns_record(attrs)
      assert record.name == "www"
      assert record.type == "A"
      assert record.value == "192.168.1.100"
      assert record.ttl == 300
      assert record.managed == true
    end

    test "creates a CNAME record" do
      zone = insert(:dns_zone)

      attrs = %{
        name: "blog",
        type: "CNAME",
        value: "www.example.com",
        dns_zone_id: zone.id,
        ttl: 3600
      }

      assert {:ok, record} = Networking.create_dns_record(attrs)
      assert record.type == "CNAME"
      assert record.ttl == 3600
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Networking.create_dns_record(%{})
      assert errors_on(changeset).name != []
      assert errors_on(changeset).type != []
      assert errors_on(changeset).value != []
      assert errors_on(changeset).dns_zone_id != []
    end

    test "validates record type" do
      zone = insert(:dns_zone)

      attrs = %{
        name: "test",
        type: "INVALID",
        value: "1.2.3.4",
        dns_zone_id: zone.id
      }

      assert {:error, changeset} = Networking.create_dns_record(attrs)
      assert errors_on(changeset).type != []
    end
  end

  describe "update_dns_record/2" do
    test "updates record value" do
      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone, value: "192.168.1.1")

      assert {:ok, updated} = Networking.update_dns_record(record, %{value: "10.0.0.1"})
      assert updated.value == "10.0.0.1"
    end
  end

  describe "delete_dns_record/1" do
    test "deletes a record" do
      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone)
      assert {:ok, _} = Networking.delete_dns_record(record)
      assert {:error, :not_found} = Networking.get_dns_record(record.id)
    end
  end

  # --- Sync / Push ---

  describe "sync_zones_from_registrar/0" do
    test "creates zones from registrar domains" do
      Homelab.Mocks.RegistrarProvider
      |> expect(:list_domains, fn ->
        {:ok,
         [
           %{name: "example.com", provider_zone_id: "zone_123", status: "active", name_servers: []},
           %{name: "example.org", provider_zone_id: "zone_456", status: "active", name_servers: []}
         ]}
      end)
      |> expect(:driver_id, fn -> "mock_registrar" end)
      |> expect(:driver_id, fn -> "mock_registrar" end)

      assert {:ok, results} = Networking.sync_zones_from_registrar()
      assert length(results) == 2

      zones = Networking.list_dns_zones()
      names = Enum.map(zones, & &1.name)
      assert "example.com" in names
      assert "example.org" in names
    end

    test "updates existing zones on re-sync" do
      insert(:dns_zone, name: "example.com", provider: "old_provider", sync_status: :pending)

      Homelab.Mocks.RegistrarProvider
      |> expect(:list_domains, fn ->
        {:ok,
         [%{name: "example.com", provider_zone_id: "zone_123", status: "active", name_servers: []}]}
      end)
      |> expect(:driver_id, fn -> "mock_registrar" end)

      assert {:ok, _results} = Networking.sync_zones_from_registrar()

      assert {:ok, zone} = Networking.get_dns_zone_by_name("example.com")
      assert zone.provider == "mock_registrar"
      assert zone.sync_status == :synced
      assert zone.provider_zone_id == "zone_123"
    end

    test "returns error when registrar fails" do
      Homelab.Mocks.RegistrarProvider
      |> expect(:list_domains, fn -> {:error, :api_error} end)

      assert {:error, :api_error} = Networking.sync_zones_from_registrar()
    end
  end

  describe "ensure_deployment_dns_records/2" do
    test "creates DNS records for a deployment with public IP" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      deployment = insert(:deployment, domain: "myapp.example.com")

      ip_config = %{public_ip: "203.0.113.1", internal_ip: nil}
      assert {:ok, results} = Networking.ensure_deployment_dns_records(deployment, ip_config)
      assert length(results) == 1

      assert {:ok, zone} = Networking.get_dns_zone_by_name("example.com")
      records = Networking.list_dns_records_for_zone(zone.id)
      assert length(records) == 1

      record = hd(records)
      assert record.name == "myapp"
      assert record.type == "A"
      assert record.value == "203.0.113.1"
      assert record.scope == :public
    end

    test "creates both public and internal records" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      deployment = insert(:deployment, domain: "myapp.example.com")

      ip_config = %{public_ip: "203.0.113.1", internal_ip: "192.168.1.10"}
      assert {:ok, results} = Networking.ensure_deployment_dns_records(deployment, ip_config)
      assert length(results) == 2
    end

    test "returns empty list when deployment has no domain" do
      deployment = insert(:deployment, domain: nil)
      assert {:ok, []} = Networking.ensure_deployment_dns_records(deployment, %{})
    end

    test "returns empty list when domain is empty string" do
      deployment = insert(:deployment, domain: "")
      assert {:ok, []} = Networking.ensure_deployment_dns_records(deployment, %{})
    end

    test "reuses existing zone if one matches the domain" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r1"}} end)

      existing_zone = insert(:dns_zone, name: "example.com", provider: "cloudflare")
      deployment = insert(:deployment, domain: "sub.example.com")

      ip_config = %{public_ip: "1.2.3.4"}
      assert {:ok, _} = Networking.ensure_deployment_dns_records(deployment, ip_config)

      zones = Networking.list_dns_zones()
      assert length(zones) == 1
      assert hd(zones).id == existing_zone.id
    end
  end

  describe "cleanup_deployment_dns_records/1" do
    test "deletes managed records for a deployment" do
      deployment = insert(:deployment)
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, deployment: deployment, managed: true)
      insert(:dns_record, dns_zone: zone, deployment: deployment, managed: false)

      assert :ok = Networking.cleanup_deployment_dns_records(deployment.id)

      remaining = Networking.list_dns_records_for_deployment(deployment.id)
      assert length(remaining) == 1
      assert hd(remaining).managed == false
    end

    test "pushes deletions to provider for records with provider_record_id" do
      Homelab.Mocks.DnsProvider
      |> expect(:delete_record, fn _zone_ref, "prov_rec_1" -> :ok end)

      deployment = insert(:deployment)
      zone = insert(:dns_zone, provider_zone_id: "zone_abc")

      insert(:dns_record,
        dns_zone: zone,
        deployment: deployment,
        managed: true,
        scope: :public,
        provider_record_id: "prov_rec_1"
      )

      assert :ok = Networking.cleanup_deployment_dns_records(deployment.id)
    end
  end

  describe "push_record_to_provider/1" do
    test "pushes record to DNS provider and stores provider_record_id" do
      Homelab.Mocks.DnsProvider
      |> expect(:create_record, fn _zone_ref, record_attrs ->
        assert record_attrs.name == "www"
        assert record_attrs.type == "A"
        {:ok, %{id: "provider_rec_42"}}
      end)

      zone = insert(:dns_zone, name: "example.com")
      record = insert(:dns_record, dns_zone: zone, name: "www", type: "A", scope: :public)

      Networking.push_record_to_provider(record)

      assert {:ok, updated} = Networking.get_dns_record(record.id)
      assert updated.provider_record_id == "provider_rec_42"
    end

    test "handles provider error gracefully" do
      Homelab.Mocks.DnsProvider
      |> expect(:create_record, fn _zone, _record -> {:error, :timeout} end)

      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone, scope: :public)

      Networking.push_record_to_provider(record)

      assert {:ok, unchanged} = Networking.get_dns_record(record.id)
      assert unchanged.provider_record_id == nil
    end
  end

  describe "change_domain/2" do
    test "returns a changeset" do
      deployment = insert(:deployment)
      domain = insert(:domain, deployment: deployment)
      changeset = Networking.change_domain(domain, %{tls_status: :active})
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "change_dns_zone/2" do
    test "returns a changeset" do
      zone = insert(:dns_zone)
      changeset = Networking.change_dns_zone(zone, %{provider: "new_provider"})
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "change_dns_record/2" do
    test "returns a changeset" do
      zone = insert(:dns_zone)
      record = insert(:dns_record, dns_zone: zone)
      changeset = Networking.change_dns_record(record, %{value: "10.0.0.1"})
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "sync_zones_from_registrar/0 no registrar" do
    test "returns error when no registrar is configured" do
      original = Application.get_env(:homelab, :registrar)
      Application.put_env(:homelab, :registrar, nil)

      on_exit(fn -> Application.put_env(:homelab, :registrar, original) end)

      assert {:error, :no_registrar_configured} = Networking.sync_zones_from_registrar()
    end
  end

  describe "push_record_to_provider/1 edge cases" do
    test "does not update provider_record_id when provider returns no id" do
      Homelab.Mocks.DnsProvider
      |> expect(:create_record, fn _zone, _record -> {:ok, %{}} end)

      zone = insert(:dns_zone, name: "example.com")
      record = insert(:dns_record, dns_zone: zone, scope: :public)

      Networking.push_record_to_provider(record)

      assert {:ok, unchanged} = Networking.get_dns_record(record.id)
      assert unchanged.provider_record_id == nil
    end

    test "pushes record to internal DNS provider" do
      Homelab.Mocks.DnsProvider
      |> expect(:create_record, fn _zone, record_attrs ->
        assert record_attrs.name == "internal-host"
        {:ok, %{id: "internal_rec_1"}}
      end)

      zone = insert(:dns_zone, name: "example.com")
      record = insert(:dns_record, dns_zone: zone, name: "internal-host", scope: :internal)

      Networking.push_record_to_provider(record)

      assert {:ok, updated} = Networking.get_dns_record(record.id)
      assert updated.provider_record_id == "internal_rec_1"
    end

    test "pushes record to both public and internal providers" do
      Homelab.Mocks.DnsProvider
      |> expect(:create_record, 2, fn _zone, _record -> {:ok, %{id: "both_rec"}} end)

      zone = insert(:dns_zone, name: "example.com")
      record = insert(:dns_record, dns_zone: zone, scope: :both)

      Networking.push_record_to_provider(record)

      assert {:ok, updated} = Networking.get_dns_record(record.id)
      assert updated.provider_record_id == "both_rec"
    end
  end

  describe "ensure_deployment_dns_records/2 additional paths" do
    test "creates only internal record when public_ip is nil" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r_int"}} end)

      deployment = insert(:deployment, domain: "app.example.com")

      ip_config = %{public_ip: nil, internal_ip: "10.0.0.5"}
      assert {:ok, results} = Networking.ensure_deployment_dns_records(deployment, ip_config)
      assert length(results) == 1

      assert {:ok, zone} = Networking.get_dns_zone_by_name("example.com")
      records = Networking.list_dns_records_for_zone(zone.id)
      assert length(records) == 1
      assert hd(records).scope == :internal
      assert hd(records).value == "10.0.0.5"
    end

    test "updates existing DNS record on re-call (upsert)" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r_upsert"}} end)

      zone = insert(:dns_zone, name: "example.com")
      deployment = insert(:deployment, domain: "app.example.com")

      insert(:dns_record,
        dns_zone: zone,
        deployment: deployment,
        name: "app",
        type: "A",
        value: "1.1.1.1",
        scope: :public,
        managed: true
      )

      ip_config = %{public_ip: "2.2.2.2", internal_ip: nil}
      assert {:ok, _results} = Networking.ensure_deployment_dns_records(deployment, ip_config)

      records = Networking.list_dns_records_for_zone(zone.id)
      public_records = Enum.filter(records, &(&1.scope == :public))
      assert length(public_records) == 1
      assert hd(public_records).value == "2.2.2.2"
    end

    test "handles root domain (record name becomes @)" do
      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "r_root"}} end)

      deployment = insert(:deployment, domain: "example.com")

      ip_config = %{public_ip: "5.5.5.5"}
      assert {:ok, results} = Networking.ensure_deployment_dns_records(deployment, ip_config)
      assert length(results) == 1

      assert {:ok, zone} = Networking.get_dns_zone_by_name("example.com")
      records = Networking.list_dns_records_for_zone(zone.id)
      assert hd(records).name == "@"
    end
  end

  describe "cleanup_deployment_dns_records/1 edge cases" do
    test "skips provider deletion when record has no provider_record_id" do
      deployment = insert(:deployment)
      zone = insert(:dns_zone)

      insert(:dns_record,
        dns_zone: zone,
        deployment: deployment,
        managed: true,
        provider_record_id: nil
      )

      assert :ok = Networking.cleanup_deployment_dns_records(deployment.id)
      assert Networking.list_dns_records_for_deployment(deployment.id) == []
    end
  end
end
