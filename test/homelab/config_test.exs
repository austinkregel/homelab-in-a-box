defmodule Homelab.ConfigTest do
  use ExUnit.Case, async: true

  alias Homelab.Config

  describe "orchestrator/0" do
    test "returns configured orchestrator module" do
      assert Config.orchestrator() == Homelab.Mocks.Orchestrator
    end
  end

  describe "identity_broker/0" do
    test "returns configured identity broker module" do
      assert Config.identity_broker() == Homelab.Mocks.IdentityBroker
    end
  end

  describe "gateway/0" do
    test "returns configured gateway module" do
      assert Config.gateway() == Homelab.Mocks.Gateway
    end
  end

  describe "backup_provider/0" do
    test "returns configured backup provider module" do
      assert Config.backup_provider() == Homelab.Mocks.BackupProvider
    end
  end

  describe "base_domain/0" do
    test "returns configured base domain" do
      assert is_binary(Config.base_domain())
    end
  end

  describe "tenant_setting/3" do
    test "returns setting from tenant settings map" do
      tenant = %{settings: %{"max_apps" => 10}}
      assert Config.tenant_setting(tenant, "max_apps") == 10
    end

    test "returns platform default when setting is missing" do
      tenant = %{settings: %{}}
      assert Config.tenant_setting(tenant, "max_apps") == 5
      assert Config.tenant_setting(tenant, "max_memory_mb") == 2048
      assert Config.tenant_setting(tenant, "backup_retention_days") == 30
    end

    test "returns custom default for unknown settings" do
      tenant = %{settings: %{}}
      assert Config.tenant_setting(tenant, "custom_setting", "fallback") == "fallback"
    end

    test "handles nil settings map" do
      tenant = %{settings: nil}
      assert Config.tenant_setting(tenant, "max_apps") == 5
    end
  end
end
