defmodule Homelab.Registrars.CloudflareTest do
  use Homelab.DataCase, async: false

  alias Homelab.Registrars.Cloudflare
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.cloudflare_registrar(bypass)

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

    test "returns display_name" do
      assert Cloudflare.display_name() == "Cloudflare"
    end
  end

  describe "list_domains/0" do
    test "returns zones from Cloudflare" do
      {:ok, domains} = Cloudflare.list_domains()
      assert length(domains) > 0
      assert hd(domains).name == "example.com"
    end

    test "returns error when not configured" do
      Homelab.Settings.delete("cloudflare_api_token")
      assert {:error, :not_configured} = Cloudflare.list_domains()
    end
  end

  describe "get_nameservers/1" do
    test "returns nameservers for a domain" do
      {:ok, nameservers} = Cloudflare.get_nameservers("example.com")
      assert length(nameservers) > 0
      assert "ns1.cloudflare.com" in nameservers
    end

    test "returns error for unknown domain" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"result" => [], "result_info" => %{"total_pages" => 1}}))
      end)

      Application.put_env(:homelab, Cloudflare, base_url: "http://localhost:#{bypass.port}")

      assert {:error, :zone_not_found} = Cloudflare.get_nameservers("nonexistent.com")
    end
  end
end
