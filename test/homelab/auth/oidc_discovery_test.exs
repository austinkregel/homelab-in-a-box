defmodule Homelab.Auth.OidcDiscoveryTest do
  use ExUnit.Case, async: true

  alias Homelab.Auth.OidcDiscovery

  @discovery_body %{
    "issuer" => "https://auth.example.com",
    "authorization_endpoint" => "https://auth.example.com/authorize",
    "token_endpoint" => "https://auth.example.com/token",
    "userinfo_endpoint" => "https://auth.example.com/userinfo",
    "jwks_uri" => "https://auth.example.com/.well-known/jwks.json",
    "device_authorization_endpoint" => "https://auth.example.com/device",
    "end_session_endpoint" => "https://auth.example.com/logout",
    "grant_types_supported" => ["authorization_code", "refresh_token"],
    "scopes_supported" => ["openid", "email", "profile"],
    "response_types_supported" => ["code"],
    "token_endpoint_auth_methods_supported" => ["client_secret_post"]
  }

  describe "discover/1" do
    test "fetches and parses OIDC discovery document" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@discovery_body))
      end)

      assert {:ok, discovery} = OidcDiscovery.discover("http://localhost:#{bypass.port}")
      assert discovery.issuer == "https://auth.example.com"
      assert discovery.authorization_endpoint == "https://auth.example.com/authorize"
      assert discovery.token_endpoint == "https://auth.example.com/token"
      assert discovery.userinfo_endpoint == "https://auth.example.com/userinfo"
    end

    test "strips trailing slash from issuer URL" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@discovery_body))
      end)

      assert {:ok, _} = OidcDiscovery.discover("http://localhost:#{bypass.port}/")
    end

    test "returns error for non-200 status" do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        Plug.Conn.resp(conn, 404, "Not Found")
      end)

      assert {:error, {:http_error, 404}} = OidcDiscovery.discover("http://localhost:#{bypass.port}")
    end

    test "returns error for connection failures" do
      assert {:error, {:connection_error, _}} = OidcDiscovery.discover("http://localhost:1")
    end
  end

  describe "supports_grant?/2" do
    test "returns true for supported grant types" do
      discovery = %OidcDiscovery{grant_types_supported: ["authorization_code", "refresh_token"]}
      assert OidcDiscovery.supports_grant?(discovery, "authorization_code")
      assert OidcDiscovery.supports_grant?(discovery, "refresh_token")
    end

    test "returns false for unsupported grant types" do
      discovery = %OidcDiscovery{grant_types_supported: ["authorization_code"]}
      refute OidcDiscovery.supports_grant?(discovery, "client_credentials")
    end
  end

  describe "supports_authorization_code?/1" do
    test "returns true when authorization_code is supported" do
      discovery = %OidcDiscovery{grant_types_supported: ["authorization_code"]}
      assert OidcDiscovery.supports_authorization_code?(discovery)
    end
  end

  describe "supports_device_flow?/1" do
    test "returns true when device grant type is supported" do
      discovery = %OidcDiscovery{
        grant_types_supported: ["urn:ietf:params:oauth:grant-type:device_code"],
        device_authorization_endpoint: nil
      }

      assert OidcDiscovery.supports_device_flow?(discovery)
    end

    test "returns true when device endpoint is present" do
      discovery = %OidcDiscovery{
        grant_types_supported: [],
        device_authorization_endpoint: "https://auth.example.com/device"
      }

      assert OidcDiscovery.supports_device_flow?(discovery)
    end
  end

  describe "to_json/1 and from_json/1" do
    test "round-trips through JSON" do
      discovery = %OidcDiscovery{
        issuer: "https://auth.example.com",
        authorization_endpoint: "https://auth.example.com/authorize",
        token_endpoint: "https://auth.example.com/token",
        grant_types_supported: ["authorization_code"]
      }

      json = OidcDiscovery.to_json(discovery)
      assert {:ok, restored} = OidcDiscovery.from_json(json)
      assert restored.issuer == discovery.issuer
      assert restored.grant_types_supported == discovery.grant_types_supported
    end
  end
end
