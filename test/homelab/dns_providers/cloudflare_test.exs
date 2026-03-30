defmodule Homelab.DnsProviders.CloudflareTest do
  use Homelab.DataCase, async: false

  alias Homelab.DnsProviders.Cloudflare
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.cloudflare_dns(bypass)

    Application.put_env(:homelab, Cloudflare, base_url: base_url)
    Homelab.Settings.init_cache()
    Homelab.Settings.set("cloudflare_api_token", "cf-test-token")

    on_exit(fn -> Application.delete_env(:homelab, Cloudflare) end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert Cloudflare.driver_id() == "cloudflare"
    end

    test "returns scope" do
      assert Cloudflare.scope() == :public
    end
  end

  describe "list_records/1" do
    test "returns DNS records for a zone" do
      {:ok, records} = Cloudflare.list_records("zone_123")
      assert length(records) > 0
      assert hd(records).name == "app.example.com"
    end

    test "returns error when not configured" do
      Homelab.Settings.delete("cloudflare_api_token")
      assert {:error, :not_configured} = Cloudflare.list_records("zone_123")
    end
  end

  describe "create_record/2" do
    test "creates a DNS record" do
      record = %{type: "A", name: "new.example.com", value: "1.2.3.4", ttl: 300}
      {:ok, created} = Cloudflare.create_record("zone_123", record)
      assert created.name == "new.example.com"
    end
  end

  describe "update_record/3" do
    test "updates a DNS record" do
      record = %{type: "A", name: "updated.example.com", value: "5.6.7.8", ttl: 600}
      {:ok, updated} = Cloudflare.update_record("zone_123", "rec_1", record)
      assert updated.name == "updated.example.com"
    end
  end

  describe "delete_record/2" do
    test "deletes a DNS record" do
      assert :ok = Cloudflare.delete_record("zone_123", "rec_1")
    end
  end
end
