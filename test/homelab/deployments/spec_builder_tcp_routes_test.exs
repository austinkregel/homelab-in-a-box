defmodule Homelab.Deployments.SpecBuilderTcpRoutesTest do
  @moduledoc """
  The TCP routers that make a datastore reachable by hostname.

  `async: false` for the same reason as `SpecBuilderWildcardTest`: the wildcard-certificate
  assertions read `Config.wildcard_domains/0`, whose only seam is a global ETS table that
  every async `DataCase` wipes.
  """
  use ExUnit.Case, async: false

  alias Homelab.Deployments.SpecBuilder

  defp build_tenant(overrides \\ %{}) do
    Map.merge(
      %Homelab.Tenants.Tenant{
        id: 1,
        slug: "media",
        name: "Media",
        status: :active,
        settings: %{}
      },
      overrides
    )
  end

  defp build_template(overrides) do
    Map.merge(
      %Homelab.Catalog.AppTemplate{
        id: 1,
        slug: "postgres",
        name: "Postgres",
        version: "17",
        image: "postgres:17-alpine",
        exposure_mode: :service,
        auth_integration: false,
        default_env: %{},
        required_env: [],
        volumes: [],
        ports: [%{"container" => 5432, "protocol" => "tcp"}],
        resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
        backup_policy: %{},
        health_check: %{},
        depends_on: []
      },
      overrides
    )
  end

  defp build_deployment(overrides \\ %{}, template_overrides \\ %{}) do
    tenant = build_tenant()
    template = build_template(template_overrides)

    Map.merge(
      %Homelab.Deployments.Deployment{
        id: 1,
        tenant: tenant,
        tenant_id: tenant.id,
        app_template: template,
        app_template_id: template.id,
        status: :pending,
        env_overrides: %{},
        domain: nil,
        tcp_routes: [%{"host" => "postgres-media.example.com", "port" => 5432}],
        network_children: [],
        secrets: []
      },
      overrides
    )
  end

  defp labels(deployment) do
    {:ok, spec} = SpecBuilder.build(deployment)
    spec.labels
  end

  describe "router and service labels" do
    test "a TCP route becomes a HostSNI router pointing at the container port" do
      labels = labels(build_deployment())
      router = "postgres-media-example-com-5432"

      assert labels["traefik.tcp.routers.#{router}.rule"] ==
               "HostSNI(`postgres-media.example.com`)"

      assert labels["traefik.tcp.services.#{router}.loadbalancer.server.port"] == "5432"
      assert labels["traefik.tcp.routers.#{router}.service"] == router
      assert labels["traefik.enable"] == "true"
    end

    # A TCP router with no entrypoints label binds to EVERY entrypoint, which for a
    # HostSNI rule means quietly claiming the hostname on port 80 as well.
    test "the entrypoint is always named" do
      labels = labels(build_deployment())

      assert labels["traefik.tcp.routers.postgres-media-example-com-5432.entrypoints"] ==
               "websecure"
    end

    # Without the ALPN option libpq 17 cannot complete a handshake at all: it advertises
    # the `postgresql` protocol and the shared entrypoint offers only h2/http1.1.
    test "the router carries the Postgres ALPN TLS options" do
      labels = labels(build_deployment())
      router = "postgres-media-example-com-5432"

      assert labels["traefik.tcp.routers.#{router}.tls"] == "true"
      assert labels["traefik.tcp.routers.#{router}.tls.certresolver"] == "letsencrypt"

      assert labels["traefik.tcp.routers.#{router}.tls.options"] ==
               Homelab.Infrastructure.postgres_tls_options()
    end

    # The port is part of the router name, so the second route does not overwrite the
    # first in the label map.
    test "one host on two ports is two routers" do
      deployment =
        build_deployment(%{
          tcp_routes: [
            %{"host" => "db.example.com", "port" => 5432},
            %{"host" => "db.example.com", "port" => 5433}
          ]
        })

      labels = labels(deployment)

      assert labels["traefik.tcp.services.db-example-com-5432.loadbalancer.server.port"] ==
               "5432"

      assert labels["traefik.tcp.services.db-example-com-5433.loadbalancer.server.port"] ==
               "5433"
    end

    test "a deployment with no TCP routes emits no TCP labels" do
      labels = labels(build_deployment(%{tcp_routes: []}))

      refute Enum.any?(Map.keys(labels), &String.starts_with?(&1, "traefik.tcp."))
    end
  end

  describe "which network Traefik resolves the backend on" do
    # The invariant this feature had to avoid breaking: a datastore must NOT be put on
    # the shared ingress network, where every other tenant's routed workload could reach
    # it at L3 with no proxy in the way. Traefik joins the tenant network instead.
    test "a TCP-only deployment stays off ingress and labels its tenant network" do
      {:ok, spec} = SpecBuilder.build(build_deployment())

      assert spec.routing_networks == []
      assert spec.labels["traefik.docker.network"] == "homelab_tenant_media"
    end

    test "a deployment that is also HTTP-routed resolves on ingress for both" do
      deployment =
        build_deployment(
          %{domain: "app.example.com"},
          %{exposure_mode: :public}
        )

      {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.routing_networks == ["homelab-iab-internal"]
      assert spec.labels["traefik.docker.network"] == "homelab-iab-internal"
    end
  end

  describe "exposure" do
    # There is no forwardAuth for TCP -- Traefik's TCP middleware set is ipAllowList and
    # inFlightConn. So an SSO-protected deployment cannot have a guarded TCP route, and
    # emitting an unguarded one would publish the database under a name that looks
    # protected. The changeset refuses this too; this is the second line.
    test "an SSO-protected deployment emits no TCP labels whatever the column holds" do
      deployment = build_deployment(%{}, %{exposure_mode: :sso_protected})

      labels = labels(deployment)

      refute Enum.any?(Map.keys(labels), &String.starts_with?(&1, "traefik.tcp."))
    end

    test "a private deployment carries its explicit source range as a TCP allowlist" do
      deployment =
        build_deployment(
          %{
            tcp_routes: [
              %{
                "host" => "postgres-media.example.com",
                "port" => 5432,
                "source_range" => "192.168.1.0/24"
              }
            ]
          },
          %{exposure_mode: :private}
        )

      labels = labels(deployment)
      router = "postgres-media-example-com-5432"

      assert labels["traefik.tcp.middlewares.#{router}-ipallow.ipallowlist.sourcerange"] ==
               "192.168.1.0/24"

      assert labels["traefik.tcp.routers.#{router}.middlewares"] == "#{router}-ipallow"
    end

    test "a public deployment gets no allowlist middleware" do
      deployment = build_deployment(%{}, %{exposure_mode: :public})

      labels = labels(deployment)

      refute Enum.any?(Map.keys(labels), &String.contains?(&1, "ipallowlist"))
    end
  end

  describe "certificates" do
    setup do
      previous = Application.get_env(:homelab, :base_domain)
      Application.put_env(:homelab, :base_domain, "example.com")
      on_exit(fn -> Application.put_env(:homelab, :base_domain, previous) end)
    end

    # A TCP router orders certificates exactly as an HTTP one does, so a host one label
    # under a configured wildcard must reuse that certificate rather than open its own
    # ACME order.
    test "a host under the wildcard names it instead of ordering its own certificate" do
      labels = labels(build_deployment())
      router = "postgres-media-example-com-5432"

      assert labels["traefik.tcp.routers.#{router}.tls.domains[0].main"] == "example.com"
      assert labels["traefik.tcp.routers.#{router}.tls.domains[0].sans"] == "*.example.com"
    end

    test "a host two labels down is not claimed by the wildcard" do
      deployment =
        build_deployment(%{tcp_routes: [%{"host" => "db.lab.example.com", "port" => 5432}]})

      labels = labels(deployment)

      refute Map.has_key?(
               labels,
               "traefik.tcp.routers.db-lab-example-com-5432.tls.domains[0].main"
             )

      assert labels["traefik.tcp.routers.db-lab-example-com-5432.tls.certresolver"] ==
               "letsencrypt"
    end
  end

  describe "guarded backend ports" do
    # A TCP router is a door onto a port exactly as an HTTP router is, so on a protected
    # deployment that port must not also be bound to the host with nothing in front of it.
    test "a TCP route's port counts as guarded" do
      deployment =
        build_deployment(
          %{
            tcp_routes: [
              %{"host" => "db.example.com", "port" => 5432, "source_range" => "10.0.0.0/8"}
            ]
          },
          %{exposure_mode: :private}
        )

      assert "5432" in SpecBuilder.guarded_backend_ports(deployment)
    end
  end
end
