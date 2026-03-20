defmodule Homelab.Gateways.TraefikTest do
  use ExUnit.Case, async: false

  alias Homelab.Gateways.Traefik

  setup do
    # Use a temp directory for Traefik config files
    tmp_dir = Path.join(System.tmp_dir!(), "homelab_traefik_test_#{:rand.uniform(100_000)}")
    File.mkdir_p!(tmp_dir)

    bypass = Bypass.open()

    Application.put_env(:homelab, Homelab.Gateways.Traefik,
      config_dir: tmp_dir,
      api_url: "http://localhost:#{bypass.port}",
      acme_email: "test@homelab.local"
    )

    on_exit(fn ->
      File.rm_rf!(tmp_dir)
      Application.delete_env(:homelab, Homelab.Gateways.Traefik)
    end)

    {:ok, tmp_dir: tmp_dir, bypass: bypass}
  end

  describe "register_route/3" do
    test "creates a route config file", %{tmp_dir: tmp_dir} do
      assert :ok = Traefik.register_route("app.example.com", "http://app:8080")

      config_file = Path.join(tmp_dir, "app-example-com.yml")
      assert File.exists?(config_file)

      content = File.read!(config_file)
      parsed = Jason.decode!(content)

      assert get_in(parsed, ["http", "routers", "app-example-com", "rule"]) ==
               "Host(`app.example.com`)"

      assert get_in(parsed, ["http", "services", "svc-app-example-com", "loadBalancer", "servers"]) ==
               [%{"url" => "http://app:8080"}]
    end

    test "creates sso_protected middleware by default", %{tmp_dir: tmp_dir} do
      assert :ok = Traefik.register_route("secure.example.com", "http://app:8080")

      config_file = Path.join(tmp_dir, "secure-example-com.yml")
      content = File.read!(config_file)
      parsed = Jason.decode!(content)

      middlewares = get_in(parsed, ["http", "middlewares"])
      assert Map.has_key?(middlewares, "secure-example-com-auth")
      assert get_in(middlewares, ["secure-example-com-auth", "forwardAuth"]) != nil
    end

    test "creates public route without auth middleware", %{tmp_dir: tmp_dir} do
      assert :ok =
               Traefik.register_route("public.example.com", "http://app:8080", exposure: :public)

      config_file = Path.join(tmp_dir, "public-example-com.yml")
      content = File.read!(config_file)
      parsed = Jason.decode!(content)

      middlewares = get_in(parsed, ["http", "middlewares"])
      assert middlewares == %{}
    end

    test "creates private route with IP allowlist", %{tmp_dir: tmp_dir} do
      assert :ok =
               Traefik.register_route("internal.example.com", "http://app:8080",
                 exposure: :private
               )

      config_file = Path.join(tmp_dir, "internal-example-com.yml")
      content = File.read!(config_file)
      parsed = Jason.decode!(content)

      middlewares = get_in(parsed, ["http", "middlewares"])
      assert Map.has_key?(middlewares, "internal-example-com-ipwhitelist")

      source_range =
        get_in(middlewares, ["internal-example-com-ipwhitelist", "ipAllowList", "sourceRange"])

      assert "10.0.0.0/8" in source_range
      assert "192.168.0.0/16" in source_range
    end

    test "includes TLS cert resolver", %{tmp_dir: tmp_dir} do
      assert :ok = Traefik.register_route("tls.example.com", "http://app:8080")

      config_file = Path.join(tmp_dir, "tls-example-com.yml")
      content = File.read!(config_file)
      parsed = Jason.decode!(content)

      tls = get_in(parsed, ["http", "routers", "tls-example-com", "tls"])
      assert tls["certResolver"] == "letsencrypt"
    end
  end

  describe "remove_route/1" do
    test "removes existing route config file", %{tmp_dir: tmp_dir} do
      Traefik.register_route("remove-me.example.com", "http://app:8080")
      config_file = Path.join(tmp_dir, "remove-me-example-com.yml")
      assert File.exists?(config_file)

      assert :ok = Traefik.remove_route("remove-me.example.com")
      refute File.exists?(config_file)
    end

    test "returns :ok for nonexistent route" do
      assert :ok = Traefik.remove_route("nonexistent.example.com")
    end
  end

  describe "list_routes/0" do
    test "returns list of configured routes", %{tmp_dir: _tmp_dir} do
      Traefik.register_route("app1.example.com", "http://app1:8080")
      Traefik.register_route("app2.example.com", "http://app2:8080")

      assert {:ok, routes} = Traefik.list_routes()
      assert length(routes) == 2

      domains = Enum.map(routes, & &1.domain) |> Enum.sort()
      assert "app1-example-com" in domains
      assert "app2-example-com" in domains
    end

    test "returns empty list when no routes configured" do
      assert {:ok, []} = Traefik.list_routes()
    end
  end

  describe "provision_tls/1" do
    test "queries Traefik API for TLS status", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/http/routers/app-example-com", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "tls" => %{
              "certResolver" => "letsencrypt"
            }
          })
        )
      end)

      assert {:ok, tls_info} = Traefik.provision_tls("app.example.com")
      assert tls_info.domain == "app.example.com"
      assert tls_info.cert_resolver == "letsencrypt"
      assert tls_info.status == :active
    end

    test "returns error for nonexistent route", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/http/routers/missing-example-com", fn conn ->
        conn
        |> Plug.Conn.resp(404, "")
      end)

      assert {:error, :route_not_found} = Traefik.provision_tls("missing.example.com")
    end
  end

  describe "check_tls_expiry/1" do
    test "returns estimated expiry when not available from API", %{bypass: bypass} do
      Bypass.expect_once(bypass, "GET", "/api/http/routers/app-example-com", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"tls" => %{}}))
      end)

      assert {:ok, %DateTime{} = expiry} = Traefik.check_tls_expiry("app.example.com")
      # Should be approximately 90 days from now
      diff = DateTime.diff(expiry, DateTime.utc_now(), :day)
      assert diff >= 89 and diff <= 91
    end

    test "parses expiry date from API response", %{bypass: bypass} do
      future = DateTime.add(DateTime.utc_now(), 60 * 24 * 3600, :second)
      future_str = DateTime.to_iso8601(future)

      Bypass.expect_once(bypass, "GET", "/api/http/routers/app-example-com", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(
          200,
          Jason.encode!(%{
            "tls" => %{"notAfter" => future_str}
          })
        )
      end)

      assert {:ok, %DateTime{}} = Traefik.check_tls_expiry("app.example.com")
    end
  end
end
