defmodule Homelab.Catalog.Enrichers.InfraDetectorTest do
  use Homelab.DataCase, async: false

  alias Homelab.Catalog.Enrichers.InfraDetector

  setup do
    Homelab.Settings.init_cache()
    :ok
  end

  describe "detect/2" do
    test "detects proxy-related env vars" do
      env = [%{"key" => "TRUSTED_PROXIES", "value" => ""}]
      results = InfraDetector.detect(env)
      proxy = Enum.find(results, &(&1.id == :proxy))
      assert proxy != nil
      assert map_size(proxy.fills) > 0
    end

    test "detects app URL env vars with domain" do
      env = [%{"key" => "APP_URL", "value" => ""}]
      results = InfraDetector.detect(env, domain: "myapp.example.com")
      url = Enum.find(results, &(&1.id == :app_url))
      assert url != nil
      assert url.fills["APP_URL"] =~ "myapp.example.com"
    end

    test "detects timezone env vars" do
      env = [%{"key" => "TZ", "value" => ""}]
      results = InfraDetector.detect(env)
      tz = Enum.find(results, &(&1.id == :timezone))
      assert tz != nil
      assert is_binary(tz.fills["TZ"])
    end

    test "skips env vars that already have values" do
      env = [%{"key" => "APP_URL", "value" => "https://already-set.com"}]
      results = InfraDetector.detect(env)
      assert results == [] || Enum.all?(results, &(&1.fills == %{}))
    end

    test "returns empty for unrelated env vars" do
      env = [%{"key" => "MY_CUSTOM_VAR", "value" => ""}]
      assert InfraDetector.detect(env) == []
    end

    test "detects multiple categories simultaneously" do
      env = [
        %{"key" => "TRUSTED_PROXIES", "value" => ""},
        %{"key" => "APP_URL", "value" => ""},
        %{"key" => "TZ", "value" => ""}
      ]

      results = InfraDetector.detect(env, domain: "test.local")
      ids = Enum.map(results, & &1.id)
      assert :proxy in ids
      assert :app_url in ids
      assert :timezone in ids
    end

    test "detects OIDC env vars" do
      Homelab.Settings.set("oidc_issuer", "https://auth.example.com")
      Homelab.Settings.set("oidc_client_id", "my-client")
      Homelab.Settings.set("oidc_client_secret", "my-secret")

      env = [
        %{"key" => "OIDC_ISSUER", "value" => ""},
        %{"key" => "OIDC_CLIENT_ID", "value" => ""},
        %{"key" => "OIDC_CLIENT_SECRET", "value" => ""}
      ]

      results = InfraDetector.detect(env)
      oidc = Enum.find(results, &(&1.id == :oidc))
      assert oidc != nil
    end

    test "detects mail env vars" do
      env = [
        %{"key" => "MAIL_HOST", "value" => ""},
        %{"key" => "MAIL_PORT", "value" => ""},
        %{"key" => "MAIL_FROM", "value" => ""}
      ]

      results = InfraDetector.detect(env)
      mail = Enum.find(results, &(&1.id == :mail))
      assert mail != nil
      assert map_size(mail.fills) > 0
    end

    test "includes matched_keys in results" do
      env = [
        %{"key" => "TRUSTED_PROXIES", "value" => ""},
        %{"key" => "REAL_IP_FROM", "value" => ""}
      ]

      results = InfraDetector.detect(env)
      proxy = Enum.find(results, &(&1.id == :proxy))
      assert "TRUSTED_PROXIES" in proxy.matched_keys
      assert "REAL_IP_FROM" in proxy.matched_keys
    end

    test "includes all_fills for both empty and filled vars" do
      env = [
        %{"key" => "APP_URL", "value" => "https://existing.com"},
        %{"key" => "BASE_URL", "value" => ""}
      ]

      results = InfraDetector.detect(env, domain: "test.local")
      url = Enum.find(results, &(&1.id == :app_url))
      assert url != nil
      assert Map.has_key?(url.all_fills, "APP_URL")
      assert Map.has_key?(url.all_fills, "BASE_URL")
      refute Map.has_key?(url.fills, "APP_URL")
      assert Map.has_key?(url.fills, "BASE_URL")
    end
  end

  describe "resolve_proxy/3" do
    test "suggests trusted proxy CIDR for TRUSTED_PROXIES" do
      result = InfraDetector.resolve_proxy(["TRUSTED_PROXIES"], %{}, "")
      assert result["TRUSTED_PROXIES"] =~ "172.16.0.0/12"
    end

    test "suggests CIDR for REAL_IP vars" do
      result = InfraDetector.resolve_proxy(["SET_REAL_IP_FROM"], %{}, "")
      assert result["SET_REAL_IP_FROM"] =~ "172.16.0.0/12"
    end

    test "suggests header for FORWARDED vars" do
      result = InfraDetector.resolve_proxy(["FORWARDED_FOR"], %{}, "")
      assert result["FORWARDED_FOR"] == "X-Forwarded-For"
    end

    test "handles multiple keys" do
      result = InfraDetector.resolve_proxy(["TRUSTED_PROXIES", "FORWARDED_FOR"], %{}, "")
      assert map_size(result) == 2
    end
  end

  describe "resolve_app_url/3" do
    test "uses provided domain" do
      result = InfraDetector.resolve_app_url(["APP_URL"], %{}, "myapp.example.com")
      assert result["APP_URL"] == "https://myapp.example.com"
    end

    test "falls back to homelab.local without domain" do
      result = InfraDetector.resolve_app_url(["APP_URL"], %{}, "")
      assert result["APP_URL"] == "https://app.homelab.local"
    end

    test "strips https:// for DOMAIN keys" do
      result = InfraDetector.resolve_app_url(["APP_DOMAIN"], %{}, "myapp.example.com")
      assert result["APP_DOMAIN"] == "myapp.example.com"
    end

    test "strips https:// for HOSTNAME keys" do
      result = InfraDetector.resolve_app_url(["HOSTNAME"], %{}, "myapp.example.com")
      assert result["HOSTNAME"] == "myapp.example.com"
    end

    test "uses full URL for generic keys" do
      result = InfraDetector.resolve_app_url(["SITE_URL"], %{}, "myapp.example.com")
      assert result["SITE_URL"] == "https://myapp.example.com"
    end

    test "handles nil domain" do
      result = InfraDetector.resolve_app_url(["APP_URL"], %{}, nil)
      assert result["APP_URL"] == "https://app.homelab.local"
    end
  end

  describe "resolve_mail/3" do
    test "suggests port 587 for PORT keys" do
      result = InfraDetector.resolve_mail(["MAIL_PORT"], %{}, "")
      assert result["MAIL_PORT"] == "587"
    end

    test "suggests tls for ENCRYPTION keys" do
      result = InfraDetector.resolve_mail(["MAIL_ENCRYPTION"], %{}, "")
      assert result["MAIL_ENCRYPTION"] == "tls"
    end

    test "suggests noreply address for FROM keys" do
      result = InfraDetector.resolve_mail(["MAIL_FROM"], %{}, "")
      assert result["MAIL_FROM"] == "noreply@homelab.local"
    end

    test "suggests tls for SECURE keys" do
      result = InfraDetector.resolve_mail(["SMTP_SECURE"], %{}, "")
      assert result["SMTP_SECURE"] == "tls"
    end

    test "filters out empty host suggestions" do
      result = InfraDetector.resolve_mail(["SMTP_HOST"], %{}, "")
      refute Map.has_key?(result, "SMTP_HOST")
    end
  end
end
