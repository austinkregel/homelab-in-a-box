defmodule Homelab.DnsProviders.UnifiTest do
  use Homelab.DataCase, async: false

  alias Homelab.DnsProviders.Unifi
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.unifi(bypass)

    Homelab.Settings.init_cache()
    Homelab.Settings.set("unifi_host", base_url)
    Homelab.Settings.set("unifi_api_key", "test-api-key")
    Homelab.Settings.set("unifi_site", "default")
    Homelab.Settings.set("unifi_api_version", "new")

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert Unifi.driver_id() == "unifi"
    end

    test "returns display_name" do
      assert is_binary(Unifi.display_name())
    end

    test "returns description" do
      assert is_binary(Unifi.description())
    end

    test "returns scope as internal" do
      assert Unifi.scope() == :internal
    end
  end

  describe "list_records/1" do
    test "returns DNS records" do
      {:ok, records} = Unifi.list_records("_")
      assert is_list(records)
    end

    test "returns error when not configured" do
      Homelab.Settings.delete("unifi_host")
      assert {:error, :not_configured} = Unifi.list_records("_")
    end

    test "returns error when api_key missing" do
      Homelab.Settings.delete("unifi_api_key")
      assert {:error, :not_configured} = Unifi.list_records("_")
    end

    test "records have expected structure" do
      {:ok, records} = Unifi.list_records("_")

      if length(records) > 0 do
        record = hd(records)
        assert Map.has_key?(record, :id)
        assert Map.has_key?(record, :name)
        assert Map.has_key?(record, :type)
        assert Map.has_key?(record, :value)
        assert Map.has_key?(record, :ttl)
      end
    end
  end

  describe "create_record/2" do
    test "creates a record" do
      record = %{type: "A", name: "new.local", value: "10.0.0.1"}
      result = Unifi.create_record("_", record)
      assert {:ok, _} = result
    end

    test "creates a CNAME record" do
      record = %{type: "CNAME", name: "alias.local", value: "target.local"}
      result = Unifi.create_record("_", record)
      assert {:ok, _} = result
    end

    test "creates a record with TTL" do
      record = %{type: "A", name: "ttl.local", value: "10.0.0.1", ttl: 600}
      result = Unifi.create_record("_", record)
      assert {:ok, _} = result
    end
  end

  describe "update_record/3" do
    test "updates a record" do
      changes = %{value: "10.0.0.99"}
      result = Unifi.update_record("_", "rec_1", changes)
      assert {:ok, _} = result
    end
  end

  describe "delete_record/2" do
    test "deletes a record by id" do
      assert :ok = Unifi.delete_record("_", "rec_1")
    end
  end

  describe "legacy API mode" do
    setup do
      Homelab.Settings.set("unifi_api_version", "legacy")
      :ok
    end

    test "list_records works in legacy mode" do
      {:ok, records} = Unifi.list_records("_")
      assert is_list(records)
    end

    test "create_record works in legacy mode" do
      record = %{type: "A", name: "legacy.local", value: "10.0.0.1"}
      result = Unifi.create_record("_", record)
      assert {:ok, _} = result
    end

    test "delete_record works in legacy mode" do
      assert :ok = Unifi.delete_record("_", "rec_1")
    end
  end
end
