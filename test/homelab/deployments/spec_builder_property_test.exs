defmodule Homelab.Deployments.SpecBuilderPropertyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Homelab.Deployments.SpecBuilder

  defp slug_gen do
    gen all(base <- string(:alphanumeric, min_length: 3, max_length: 15)) do
      String.downcase(base)
    end
  end

  defp tenant_gen do
    gen all(
          slug <- slug_gen(),
          name <- string(:alphanumeric, min_length: 1, max_length: 50)
        ) do
      %Homelab.Tenants.Tenant{
        id: System.unique_integer([:positive]),
        slug: slug,
        name: name,
        status: :active,
        settings: %{}
      }
    end
  end

  defp app_template_gen do
    gen all(
          slug <- slug_gen(),
          memory_mb <- integer(64..4096),
          cpu_shares <- integer(256..4096)
        ) do
      %Homelab.Catalog.AppTemplate{
        id: System.unique_integer([:positive]),
        slug: slug,
        name: slug,
        version: "1.0.0",
        image: "#{slug}:latest",
        exposure_mode: :sso_protected,
        auth_integration: true,
        default_env: %{"APP_ENV" => "production"},
        required_env: [],
        volumes: [%{"container_path" => "/data"}],
        ports: [],
        resource_limits: %{"memory_mb" => memory_mb, "cpu_shares" => cpu_shares},
        backup_policy: %{"enabled" => true},
        health_check: %{},
        depends_on: []
      }
    end
  end

  defp deployment_gen(tenant, template) do
    constant(%Homelab.Deployments.Deployment{
      id: System.unique_integer([:positive]),
      tenant: tenant,
      tenant_id: tenant.id,
      app_template: template,
      app_template_id: template.id,
      status: :pending,
      env_overrides: %{}
    })
  end

  property "service names are always valid Docker service names" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      {:ok, spec} = SpecBuilder.build(deployment)

      # Docker service names: start with alphanumeric, then alphanumeric + _.-
      assert spec.service_name =~ ~r/^[a-zA-Z0-9][a-zA-Z0-9_.-]*$/,
             "Service name '#{spec.service_name}' is not a valid Docker service name"
    end
  end

  property "resource limits are always positive" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.memory_limit > 0, "Memory limit must be positive"
      assert spec.cpu_limit > 0, "CPU limit must be positive"
    end
  end

  property "tenant isolation: volume paths always include tenant slug" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      {:ok, spec} = SpecBuilder.build(deployment)

      Enum.each(spec.volumes, fn vol ->
        assert String.contains?(vol.source, tenant.slug),
               "Volume path #{vol.source} must include tenant slug #{tenant.slug}"
      end)
    end
  end

  property "tenant isolation: network always includes tenant slug" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      {:ok, spec} = SpecBuilder.build(deployment)

      assert String.contains?(spec.network, tenant.slug),
             "Network #{spec.network} must include tenant slug #{tenant.slug}"
    end
  end

  property "OIDC env vars are set when auth_integration is true" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      template = %{template | auth_integration: true}
      deployment = %{deployment | app_template: template}

      {:ok, spec} = SpecBuilder.build(deployment)

      assert Map.has_key?(spec.env, "OIDC_CLIENT_ID"),
             "OIDC_CLIENT_ID must be set when auth_integration is true"

      assert Map.has_key?(spec.env, "OIDC_ISSUER")
      assert Map.has_key?(spec.env, "OIDC_REDIRECT_URI")
    end
  end

  property "OIDC env vars are NOT set when auth_integration is false" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      template = %{template | auth_integration: false}
      deployment = %{deployment | app_template: template}

      {:ok, spec} = SpecBuilder.build(deployment)

      refute Map.has_key?(spec.env, "OIDC_CLIENT_ID"),
             "OIDC_CLIENT_ID must NOT be set when auth_integration is false"
    end
  end

  property "required_env validation rejects missing variables" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            required_key <- string(:alphanumeric, min_length: 3, max_length: 20)
          ) do
      template = %{template | required_env: [required_key]}

      deployment = %Homelab.Deployments.Deployment{
        id: 1,
        tenant: tenant,
        tenant_id: tenant.id,
        app_template: template,
        app_template_id: template.id,
        status: :pending,
        env_overrides: %{}
      }

      assert {:error, {:missing_required_env, [^required_key]}} =
               SpecBuilder.build(deployment)
    end
  end

  property "labels always include managed flag" do
    check all(
            tenant <- tenant_gen(),
            template <- app_template_gen(),
            deployment <- deployment_gen(tenant, template)
          ) do
      {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["homelab.managed"] == "true"
      assert spec.labels["homelab.tenant"] == tenant.slug
      assert spec.labels["homelab.app"] == template.slug
    end
  end
end
