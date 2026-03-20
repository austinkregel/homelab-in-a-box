defmodule Homelab.Networking.DnsZoneTest do
  use Homelab.DataCase, async: true

  alias Homelab.Networking
  import Homelab.Factory

  describe "list_dns_zones/0" do
    test "returns all zones ordered by name" do
      insert(:dns_zone, name: "bravo.example.com")
      insert(:dns_zone, name: "alpha.example.com")

      zones = Networking.list_dns_zones()
      assert length(zones) == 2
      assert hd(zones).name == "alpha.example.com"
    end
  end

  describe "get_dns_zone/1" do
    test "returns zone by id" do
      zone = insert(:dns_zone)
      assert {:ok, found} = Networking.get_dns_zone(zone.id)
      assert found.id == zone.id
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_dns_zone(999)
    end
  end

  describe "get_dns_zone_by_name/1" do
    test "returns zone by name" do
      insert(:dns_zone, name: "myzone.example.com")
      assert {:ok, found} = Networking.get_dns_zone_by_name("myzone.example.com")
      assert found.name == "myzone.example.com"
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Networking.get_dns_zone_by_name("nonexistent.com")
    end
  end

  describe "create_dns_zone/1" do
    test "creates a zone with valid attrs" do
      attrs = %{name: "newzone.example.com", provider: "cloudflare"}
      assert {:ok, zone} = Networking.create_dns_zone(attrs)
      assert zone.name == "newzone.example.com"
      assert zone.provider == "cloudflare"
      assert zone.sync_status == :pending
    end

    test "returns error with invalid name" do
      attrs = %{name: "INVALID ZONE!"}
      assert {:error, changeset} = Networking.create_dns_zone(attrs)
      assert errors_on(changeset).name != []
    end

    test "enforces unique name" do
      insert(:dns_zone, name: "taken.example.com")
      attrs = %{name: "taken.example.com"}
      assert {:error, changeset} = Networking.create_dns_zone(attrs)
      assert errors_on(changeset).name != []
    end
  end

  describe "update_dns_zone/2" do
    test "updates zone attributes" do
      zone = insert(:dns_zone)
      assert {:ok, updated} = Networking.update_dns_zone(zone, %{sync_status: :synced})
      assert updated.sync_status == :synced
    end
  end

  describe "delete_dns_zone/1" do
    test "deletes a zone" do
      zone = insert(:dns_zone)
      assert {:ok, _} = Networking.delete_dns_zone(zone)
      assert {:error, :not_found} = Networking.get_dns_zone(zone.id)
    end

    test "cascades to dns_records" do
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone)

      assert {:ok, _} = Networking.delete_dns_zone(zone)
      assert Networking.list_dns_records_for_zone(zone.id) == []
    end
  end
end
