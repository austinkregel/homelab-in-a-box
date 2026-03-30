defmodule Homelab.ConfigTest do
  use Homelab.DataCase, async: false

  alias Homelab.Config

  describe "single-choice drivers via Application env" do
    test "orchestrator/0 returns configured mock module" do
      assert Config.orchestrator() == Homelab.Mocks.Orchestrator
    end

    test "gateway/0 returns configured mock module" do
      assert Config.gateway() == Homelab.Mocks.Gateway
    end

    test "backup_provider/0 returns configured mock module" do
      assert Config.backup_provider() == Homelab.Mocks.BackupProvider
    end

    test "identity_broker/0 returns configured mock module" do
      assert Config.identity_broker() == Homelab.Mocks.IdentityBroker
    end

    test "registrar/0 returns configured mock module" do
      assert Config.registrar() == Homelab.Mocks.RegistrarProvider
    end

    test "public_dns_provider/0 returns configured mock module" do
      assert Config.public_dns_provider() == Homelab.Mocks.DnsProvider
    end

    test "internal_dns_provider/0 returns configured mock module" do
      assert Config.internal_dns_provider() == Homelab.Mocks.DnsProvider
    end
  end

  describe "single-choice driver resolution via Settings fallback" do
    test "returns nil when Application env is nil and no Setting is stored" do
      original = Application.get_env(:homelab, :orchestrator)
      Application.put_env(:homelab, :orchestrator, nil)
      on_exit(fn -> Application.put_env(:homelab, :orchestrator, original) end)

      Homelab.Settings.init_cache()
      Homelab.Settings.delete("orchestrator")

      assert Config.orchestrator() == nil
    end
  end

  describe "available driver lists" do
    test "orchestrators/0 returns list of modules" do
      mods = Config.orchestrators()
      assert is_list(mods)
    end

    test "gateways/0 returns list of modules" do
      mods = Config.gateways()
      assert is_list(mods)
    end

    test "backup_providers/0 returns list of modules" do
      mods = Config.backup_providers()
      assert is_list(mods)
    end

    test "identity_brokers/0 returns list of modules" do
      mods = Config.identity_brokers()
      assert is_list(mods)
    end

    test "registrars/0 returns list of modules" do
      mods = Config.registrars()
      assert is_list(mods)
    end

    test "dns_providers/0 returns list of modules" do
      mods = Config.dns_providers()
      assert is_list(mods)
    end
  end

  describe "registries/0" do
    test "returns configured test registries" do
      registries = Config.registries()
      assert is_list(registries)
      assert Homelab.Registries.DockerHub in registries
    end
  end

  describe "application_catalogs/0" do
    test "returns list of catalog modules" do
      catalogs = Config.application_catalogs()
      assert is_list(catalogs)
    end
  end

  describe "available_registry_ids/0" do
    test "always includes dockerhub" do
      ids = Config.available_registry_ids()
      assert "dockerhub" in ids
    end

    test "returns unique IDs" do
      ids = Config.available_registry_ids()
      assert ids == Enum.uniq(ids)
    end
  end

  describe "registry_for_image/1" do
    test "returns dockerhub for nil" do
      assert Config.registry_for_image(nil) == "dockerhub"
    end

    test "returns dockerhub for empty string" do
      assert Config.registry_for_image("") == "dockerhub"
    end

    test "returns ghcr for ghcr.io/ prefixed images" do
      assert Config.registry_for_image("ghcr.io/owner/repo:latest") == "ghcr"
    end

    test "returns ecr for public.ecr.aws/ prefixed images" do
      assert Config.registry_for_image("public.ecr.aws/myrepo/app:v1") == "ecr"
    end

    test "returns dockerhub for lscr.io/ prefixed images" do
      assert Config.registry_for_image("lscr.io/linuxserver/nginx:latest") == "dockerhub"
    end

    test "returns dockerhub for docker.io/ prefixed images" do
      assert Config.registry_for_image("docker.io/library/nginx:latest") == "dockerhub"
    end

    test "returns dockerhub for plain image names" do
      assert Config.registry_for_image("nginx:latest") == "dockerhub"
      assert Config.registry_for_image("myuser/myapp:v2") == "dockerhub"
    end
  end

  describe "image_pullable?/1" do
    test "returns true for dockerhub images" do
      assert Config.image_pullable?("nginx:latest")
    end

    test "returns true for nil (defaults to dockerhub)" do
      assert Config.image_pullable?(nil)
    end
  end

  describe "base_domain/0" do
    test "returns a binary string" do
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

    test "returns nil for unknown setting with no default" do
      tenant = %{settings: %{}}
      assert Config.tenant_setting(tenant, "nonexistent") == nil
    end

    test "handles nil settings map" do
      tenant = %{settings: nil}
      assert Config.tenant_setting(tenant, "max_apps") == 5
    end
  end
end
