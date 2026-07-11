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
      # Primary network is the tenant-scoped PRIVATE app network (web ↔ datastores),
      # never joined by Traefik.
      assert spec.network == "homelab_tenant_friends"
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
      refute Map.has_key?(spec.labels, "homelab.adopted")
    end

    test "adopted templates carry the homelab.adopted label" do
      tenant = build_tenant(%{slug: "friends"})
      template = build_template(%{slug: "adopted-pg", source: "adopted"})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["homelab.adopted"] == "true"
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

  describe "adoption: volume passthrough and user" do
    test "passes an explicit volume source and type through verbatim" do
      tenant = build_tenant()

      template =
        build_template(%{
          volumes: [
            %{
              "container_path" => "/var/lib/postgresql/data",
              "source" => "homelab-managed-pg",
              "type" => "volume"
            },
            %{
              "container_path" => "/etc/app",
              "source" => "/srv/homelab/app/etc",
              "type" => "bind"
            }
          ]
        })

      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert %{source: "homelab-managed-pg", target: "/var/lib/postgresql/data", type: "volume"} in spec.volumes

      assert %{source: "/srv/homelab/app/etc", target: "/etc/app", type: "bind"} in spec.volumes
    end

    test "still computes a synthetic volume name when no source is given" do
      tenant = build_tenant()
      template = build_template(%{volumes: [%{"container_path" => "/data"}]})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert [%{source: "homelab-friends-nextcloud-data", target: "/data", type: "volume"}] =
               spec.volumes
    end

    test "threads the template user (uid:gid) into the spec" do
      tenant = build_tenant()
      template = build_template(%{user: "999:999"})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.user == "999:999"
    end

    test "spec user is nil when the template has none" do
      tenant = build_tenant()
      deployment = build_deployment(tenant, build_template())

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.user == nil
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

  describe "deployment_network_for/2" do
    test "builds a per-deployment network name from slugs" do
      assert SpecBuilder.deployment_network_for("acme", "blog") == "homelab_acme_blog_net"
    end
  end

  describe "healthcheck translation" do
    test "an HTTP path becomes a wget/curl probe against the primary port" do
      tenant = build_tenant()

      template =
        build_template(%{
          health_check: %{"path" => "/status.php"},
          ports: [%{"internal" => 8080, "role" => "web"}]
        })

      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert ["CMD-SHELL", cmd] = spec.health_check["Test"]
      assert cmd =~ "http://localhost:8080/status.php"
      assert spec.health_check["Interval"] == 30_000_000_000
    end

    test "an explicit command check passes through" do
      tenant = build_tenant()
      template = build_template(%{health_check: %{"test" => ["CMD", "pg_isready", "-U", "app"]}})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.health_check["Test"] == ["CMD", "pg_isready", "-U", "app"]
    end

    test "no declared check yields no Docker healthcheck" do
      tenant = build_tenant()
      template = build_template(%{health_check: %{}})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.health_check == nil
    end

    test "an empty path is not a declared check (non-HTTP services fall back to stability)" do
      refute SpecBuilder.declares_healthcheck?(%{"path" => ""})
      refute SpecBuilder.declares_healthcheck?(%{})
      assert SpecBuilder.declares_healthcheck?(%{"path" => "/health"})
      assert SpecBuilder.declares_healthcheck?(%{"command" => "redis-cli ping"})
      assert SpecBuilder.declares_healthcheck?(%{"test" => ["CMD", "true"]})
    end
  end

  describe "host port bindings" do
    test "an ingress-routed deployment binds no host ports (Traefik-only ingress)" do
      tenant = build_tenant()

      template =
        build_template(%{
          ports: [%{"internal" => 8080, "published" => true, "host_port" => 8080}]
        })

      deployment = build_deployment(tenant, template, %{domain: "app.friends.homelab.local"})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == []
    end

    test "a :host deployment keeps its explicitly published host ports" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :host,
          ports: [%{"internal" => 9000, "published" => true, "host_port" => 9000}]
        })

      deployment = build_deployment(tenant, template, %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert [%{internal: "9000", external: "9000"}] = spec.ports
    end
  end

  describe "routing labels" do
    test "ingress route targets the shared ingress network (where Traefik reaches the web)" do
      tenant = build_tenant()
      template = build_template()
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["traefik.enable"] == "true"
      # The route resolves the backend over the ingress network, NOT the private
      # app network — Traefik never joins the app net (where the datastores live).
      assert spec.labels["traefik.docker.network"] == "homelab-iab-internal"
    end
  end

  describe "per-deployment config overrides" do
    test "ports_override wins over the template ports" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :host,
          ports: [
            %{"internal" => "1000", "external" => "1000", "published" => true, "role" => "web"}
          ]
        })

      deployment =
        build_deployment(tenant, template, %{
          domain: nil,
          ports_override: [
            %{"internal" => "8080", "external" => "9090", "published" => true, "role" => "web"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == [%{internal: "8080", external: "9090", role: "web"}]
    end

    test "nil ports_override falls back to the template ports" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :host,
          ports: [
            %{"internal" => "1000", "external" => "1000", "published" => true, "role" => "web"}
          ]
        })

      deployment = build_deployment(tenant, template, %{domain: nil, ports_override: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == [%{internal: "1000", external: "1000", role: "web"}]
    end

    test "exposure_mode_override :service publishes no host ports and marks service mode" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :private})

      deployment =
        build_deployment(tenant, template, %{
          domain: nil,
          exposure_mode_override: "service",
          ports_override: [%{"internal" => "8080", "published" => true}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == []
      assert spec.service_mode == true
    end

    test "exposure_mode_override changes routing labels without touching the template" do
      tenant = build_tenant()
      # Template default is SSO-protected; the deployment overrides to public.
      template = build_template(%{exposure_mode: :sso_protected})

      deployment =
        build_deployment(tenant, template, %{
          domain: "app.friends.test",
          exposure_mode_override: "public"
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["homelab.exposure"] == "public"
      refute Enum.any?(Map.keys(spec.labels), &String.contains?(&1, "forwardauth"))
      # The shared template is untouched.
      assert template.exposure_mode == :sso_protected
    end

    test "resource_limits_override wins over the template limits" do
      tenant = build_tenant()
      template = build_template(%{resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512}})

      deployment =
        build_deployment(tenant, template, %{
          resource_limits_override: %{"memory_mb" => 1024, "cpu_shares" => 2048}
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.memory_limit == 1024 * 1_048_576
      assert spec.cpu_limit == 2048 * 1_000_000
    end

    test "health_check_override adds a healthcheck the template lacks" do
      tenant = build_tenant()

      template =
        build_template(%{
          health_check: %{},
          ports: [%{"internal" => "8080", "published" => true}]
        })

      deployment =
        build_deployment(tenant, template, %{health_check_override: %{"path" => "/healthz"}})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert is_list(spec.health_check["Test"])
    end
  end

  describe "access model coherence (proxy XOR host)" do
    defp host_ports do
      [%{"internal" => "8080", "external" => "8080", "published" => true, "role" => "web"}]
    end

    for mode <- [:public, :sso_protected, :private] do
      test "proxy mode #{mode} never binds host ports, even with published ports + a domain" do
        tenant = build_tenant()
        template = build_template(%{exposure_mode: unquote(mode), ports: host_ports()})
        deployment = build_deployment(tenant, template, %{domain: "app.friends.test"})

        assert {:ok, spec} = SpecBuilder.build(deployment)
        assert spec.ports == []
      end
    end

    test ":host binds published ports and is never given a Traefik route" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :host, ports: host_ports()})
      # Even a stray domain must not produce routing labels for a host deployment.
      deployment = build_deployment(tenant, template, %{domain: "app.friends.test"})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == [%{internal: "8080", external: "8080", role: "web"}]
      refute spec.labels["traefik.enable"]
    end

    test "routing labels are emitted only for a proxy mode with a domain" do
      tenant = build_tenant()

      # proxy + domain → route
      proxied =
        build_deployment(tenant, build_template(%{exposure_mode: :public}), %{
          domain: "a.friends.test"
        })

      assert {:ok, spec} = SpecBuilder.build(proxied)
      assert spec.labels["traefik.enable"] == "true"

      # proxy + no domain → no route (not live yet)
      pending =
        build_deployment(tenant, build_template(%{exposure_mode: :public}), %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(pending)
      refute spec.labels["traefik.enable"]

      # :service + domain → no route (dead route avoided)
      service =
        build_deployment(tenant, build_template(%{exposure_mode: :service}), %{
          domain: "b.friends.test"
        })

      assert {:ok, spec} = SpecBuilder.build(service)
      refute spec.labels["traefik.enable"]
    end
  end
end
