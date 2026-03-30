defmodule Homelab.Deployments.SpecBuilderTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.SpecBuilder

  defp build_tenant(overrides \\ %{}) do
    Map.merge(
      %Homelab.Tenants.Tenant{
        id: 1,
        slug: "friends",
        name: "Friends",
        status: :active,
        settings: %{}
      },
      overrides
    )
  end

  defp build_template(overrides \\ %{}) do
    Map.merge(
      %Homelab.Catalog.AppTemplate{
        id: 1,
        slug: "nextcloud",
        name: "Nextcloud",
        version: "28.0",
        image: "nextcloud:28.0",
        exposure_mode: :sso_protected,
        auth_integration: true,
        default_env: %{"APP_ENV" => "production"},
        required_env: [],
        volumes: [%{"container_path" => "/data"}],
        ports: [%{"container" => 8080, "protocol" => "tcp"}],
        resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
        backup_policy: %{"enabled" => true},
        health_check: %{"path" => "/status.php"},
        depends_on: []
      },
      overrides
    )
  end

  defp build_deployment(tenant, template, overrides \\ %{}) do
    Map.merge(
      %Homelab.Deployments.Deployment{
        id: 1,
        tenant: tenant,
        tenant_id: tenant.id,
        app_template: template,
        app_template_id: template.id,
        status: :pending,
        env_overrides: %{},
        domain: "nextcloud.friends.homelab.local"
      },
      overrides
    )
  end

  describe "build/1" do
    test "builds a valid service spec" do
      tenant = build_tenant()
      template = build_template()
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.service_name == "homelab_friends_nextcloud"
      assert spec.image == "nextcloud:28.0"
      assert spec.network == "homelab_friends_nextcloud_net"
      assert spec.replicas == 1
      assert spec.tenant_id == "1"
      assert spec.deployment_id == "1"
    end

    test "sets memory limit from resource_limits" do
      tenant = build_tenant()
      template = build_template(%{resource_limits: %{"memory_mb" => 1024, "cpu_shares" => 2048}})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.memory_limit == 1024 * 1_048_576
      assert spec.cpu_limit == 2048 * 1_000_000
    end

    test "uses default resource limits when not specified" do
      tenant = build_tenant()
      template = build_template(%{resource_limits: %{}})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.memory_limit == 256 * 1_048_576
      assert spec.cpu_limit == 512 * 1_000_000
    end

    test "injects OIDC env vars when auth_integration is true" do
      tenant = build_tenant()
      template = build_template(%{auth_integration: true})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.env["OIDC_CLIENT_ID"] == "homelab_friends_nextcloud"
      assert spec.env["OIDC_ISSUER"] =~ "auth.homelab.local"
      assert spec.env["OIDC_REDIRECT_URI"] =~ "nextcloud.friends.homelab.local"
    end

    test "does not inject OIDC env vars when auth_integration is false" do
      tenant = build_tenant()
      template = build_template(%{auth_integration: false})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      refute Map.has_key?(spec.env, "OIDC_CLIENT_ID")
      refute Map.has_key?(spec.env, "OIDC_ISSUER")
    end

    test "merges default_env, oidc_env, and env_overrides correctly" do
      tenant = build_tenant()

      template =
        build_template(%{
          default_env: %{"APP_ENV" => "production", "DEBUG" => "false"},
          auth_integration: true
        })

      deployment =
        build_deployment(tenant, template, %{
          env_overrides: %{"DEBUG" => "true", "CUSTOM" => "value"}
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      # Default preserved
      assert spec.env["APP_ENV"] == "production"
      # Override wins
      assert spec.env["DEBUG"] == "true"
      # Custom added
      assert spec.env["CUSTOM"] == "value"
      # OIDC injected
      assert spec.env["OIDC_CLIENT_ID"] != nil
    end

    test "volume paths include tenant slug for isolation" do
      tenant = build_tenant(%{slug: "my-family"})

      template =
        build_template(%{
          volumes: [%{"container_path" => "/data"}, %{"container_path" => "/config"}]
        })

      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert length(spec.volumes) == 2

      Enum.each(spec.volumes, fn vol ->
        assert String.contains?(vol.source, "my-family"),
               "Volume source #{vol.source} must include tenant slug"
      end)
    end

    test "volume paths include template slug" do
      tenant = build_tenant()
      template = build_template(%{slug: "jellyfin", volumes: [%{"container_path" => "/media"}]})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert hd(spec.volumes).source =~ "jellyfin"
    end

    test "labels include managed flag and tenant info" do
      tenant = build_tenant(%{slug: "friends"})
      template = build_template(%{slug: "nextcloud", exposure_mode: :sso_protected})
      deployment = build_deployment(tenant, template, %{id: 42})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["homelab.managed"] == "true"
      assert spec.labels["homelab.tenant"] == "friends"
      assert spec.labels["homelab.app"] == "nextcloud"
      assert spec.labels["homelab.deployment_id"] == "42"
      assert spec.labels["homelab.exposure"] == "sso_protected"
    end

    test "returns error when required env vars are missing" do
      tenant = build_tenant()
      template = build_template(%{required_env: ["DATABASE_URL", "SECRET_KEY"]})
      deployment = build_deployment(tenant, template, %{env_overrides: %{}})

      assert {:error, {:missing_required_env, missing}} = SpecBuilder.build(deployment)
      assert "DATABASE_URL" in missing
      assert "SECRET_KEY" in missing
    end

    test "succeeds when all required env vars are provided" do
      tenant = build_tenant()
      template = build_template(%{required_env: ["DATABASE_URL"]})

      deployment =
        build_deployment(tenant, template, %{
          env_overrides: %{"DATABASE_URL" => "postgres://localhost/db"}
        })

      assert {:ok, _spec} = SpecBuilder.build(deployment)
    end

    test "handles nil volumes gracefully" do
      tenant = build_tenant()
      template = build_template(%{volumes: nil})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.volumes == []
    end

    test "handles nil default_env gracefully" do
      tenant = build_tenant()
      template = build_template(%{default_env: nil, auth_integration: false})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.env == %{}
    end
  end

  describe "service_name/2" do
    test "builds valid docker service name" do
      tenant = build_tenant(%{slug: "my-friends"})
      template = build_template(%{slug: "nextcloud"})

      name = SpecBuilder.service_name(tenant, template)
      assert name == "homelab_my-friends_nextcloud"
      assert name =~ ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/
    end
  end

  describe "tenant_network/1" do
    test "builds tenant-scoped network name" do
      tenant = build_tenant(%{slug: "friends"})
      assert SpecBuilder.tenant_network(tenant) == "homelab_tenant_friends"
    end
  end
end
