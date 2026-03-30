defmodule Homelab.DnsProviders.PiholeTest do
  use Homelab.DataCase, async: false

  alias Homelab.DnsProviders.Pihole
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.pihole(bypass)

    Homelab.Settings.init_cache()
    Homelab.Settings.set("pihole_url", base_url)
    Homelab.Settings.set("pihole_api_key", "test-api-key")

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert Pihole.driver_id() == "pihole"
    end

    test "returns scope as internal" do
      assert Pihole.scope() == :internal
    end
  end

  describe "list_records/1" do
    test "merges A and CNAME records" do
      {:ok, records} = Pihole.list_records("_")
      assert is_list(records)
    end

    test "returns error when not configured" do
      Homelab.Settings.delete("pihole_url")
      assert {:error, :not_configured} = Pihole.list_records("_")
    end
  end

  describe "create_record/2" do
    test "creates an A record" do
      record = %{type: "A", name: "new.local", value: "192.168.1.100"}
      assert {:ok, _} = Pihole.create_record("_", record)
    end

    test "creates a CNAME record" do
      record = %{type: "CNAME", name: "alias.local", value: "target.local"}
      assert {:ok, _} = Pihole.create_record("_", record)
    end
  end

  describe "delete_record/2" do
    test "deletes a record by name" do
      assert :ok = Pihole.delete_record("_", "A:old.local")
    end
  end
end
