defmodule Homelab.Networking.DnsRecordTest do
  use Homelab.DataCase, async: true

  alias Homelab.Networking
  import Homelab.Factory

  describe "list_dns_records_for_zone/1" do
    test "returns records for a specific zone" do
      zone = insert(:dns_zone)
      other_zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, name: "www")
      insert(:dns_record, dns_zone: other_zone, name: "mail")

      records = Networking.list_dns_records_for_zone(zone.id)
      assert length(records) == 1
      assert hd(records).name == "www"
    end

    test "orders by type then name" do
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, name: "bravo", type: "A")
      insert(:dns_record, dns_zone: zone, name: "alpha", type: "A")

      insert(:dns_record,
        dns_zone: zone,
        name: "cname",
        type: "CNAME",
        value: "alpha.example.com"
      )

      records = Networking.list_dns_records_for_zone(zone.id)
      types = Enum.map(records, & &1.type)
      assert types == ["A", "A", "CNAME"]
    end
  end

  describe "list_dns_records_for_deployment/1" do
    test "returns records for a specific deployment" do
      deployment = insert(:deployment)
      zone = insert(:dns_zone)
      insert(:dns_record, dns_zone: zone, deployment: deployment, name: "app")
      insert(:dns_record, dns_zone: zone, name: "other")

      records = Networking.list_dns_records_for_deployment(deployment.id)
      assert length(records) == 1
      assert hd(records).name == "app"
    end
  end

  describe "create_dns_record/1" do
    test "creates a record with valid attrs" do
      zone = insert(:dns_zone)

      attrs = %{
        dns_zone_id: zone.id,
        name: "www",
        type: "A",
        value: "10.0.0.1",
        ttl: 600,
        scope: :internal
      }

      assert {:ok, record} = Networking.create_dns_record(attrs)
      assert record.name == "www"
      assert record.type == "A"
      assert record.value == "10.0.0.1"
      assert record.scope == :internal
      assert record.managed == true
    end

    test "returns error with invalid type" do
      zone = insert(:dns_zone)
      attrs = %{dns_zone_id: zone.id, name: "www", type: "INVALID", value: "1.2.3.4"}
      assert {:error, changeset} = Networking.create_dns_record(attrs)
      assert errors_on(changeset).type != []
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Networking.create_dns_record(%{})
      assert errors_on(changeset).name != []
      assert errors_on(changeset).type != []
      assert errors_on(changeset).value != []
    end
  end

  describe "update_dns_record/2" do
    test "updates record attributes" do
      record = insert(:dns_record)
      assert {:ok, updated} = Networking.update_dns_record(record, %{value: "10.0.0.2"})
      assert updated.value == "10.0.0.2"
    end
  end

  describe "delete_dns_record/1" do
    test "deletes a record" do
      record = insert(:dns_record)
      assert {:ok, _} = Networking.delete_dns_record(record)
      assert {:error, :not_found} = Networking.get_dns_record(record.id)
    end
  end
end
