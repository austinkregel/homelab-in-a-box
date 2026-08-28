defmodule Homelab.Deployments.SpecBuilderTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Networking.Hostname

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
        domain: "nextcloud.friends.homelab.local",
        # Explicitly childless. `SpecBuilder` asks a donor for its children (their routes
        # go on ITS labels) and looks them up when the association is not loaded, so a
        # hand-built struct has to say so rather than send these DB-free tests to Repo.
        network_children: [],
        # Likewise: SpecBuilder merges deployment secrets into the container env and
        # looks them up when the association is not loaded.
        secrets: []
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

    test "the sso_protected forwardAuth address comes from configuration, not a literal" do
      tenant = build_tenant(%{slug: "friends"})
      template = build_template(%{slug: "nextcloud", exposure_mode: :sso_protected})
      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)

      # Found by suffix rather than by router name so this does not also assert the
      # domain-sanitizing scheme, which is a separate concern with its own tests.
      assert {_key, address} =
               Enum.find(spec.labels, fn {k, _v} ->
                 String.ends_with?(k, ".forwardauth.address")
               end)

      assert address == Homelab.Config.forward_auth_address()
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

      assert %{
               source: "homelab-managed-pg",
               target: "/var/lib/postgresql/data",
               type: "volume",
               read_only: false
             } in spec.volumes

      assert %{
               source: "/srv/homelab/app/etc",
               target: "/etc/app",
               type: "bind",
               read_only: false
             } in spec.volumes
    end

    # A mount the operator made read-only is a deliberate boundary — the app can read a
    # media library but not delete it. It had nowhere to live in the schema, so both the
    # adoption capture and the compose `:ro` suffix were dropped and every such mount
    # came back writable.
    test "a read-only mount stays read-only" do
      tenant = build_tenant()

      template =
        build_template(%{
          volumes: [
            %{
              "container_path" => "/media",
              "source" => "/srv/media",
              "type" => "bind",
              "read_only" => true
            }
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(build_deployment(tenant, template))

      assert [%{target: "/media", read_only: true}] = spec.volumes
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

  # `deployment_network/2` and `deployment_network_for/2` are gone. They named
  # `homelab_<tenant>_<app>_net`, a network nothing was ever attached to — retained only
  # so publish/unpublish had something to connect Traefik to, which is why "severing a
  # route" did nothing at all. Reachability is now the WORKLOAD's membership of the
  # shared ingress network, so there is no name left to build.
  test "the vestigial per-deployment network helpers are gone" do
    refute function_exported?(SpecBuilder, :deployment_network, 2)
    refute function_exported?(SpecBuilder, :deployment_network_for, 2)
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

  # The plane already provisions ONE wildcard — `Infrastructure.self_ingress_yaml/2`
  # writes `main: <base_domain>` + `sans: *.<base_domain>` — so a deployment one label
  # under the base domain is already covered by a certificate that exists.
  #
  # Routers emitted `tls` + `certresolver` and no `tls.domains`, which makes Traefik read
  # the domain off the Host rule and order a SEPARATE single-name certificate. Naming the
  # wildcard is what makes the router reuse it, and it is also what makes two routers on
  # the same wildcard share one ACME order instead of racing for their own.
  describe "wildcard certificate reuse" do
    # RESTORED, not deleted. `config/config.exs:13` sets `:base_domain`, and deleting it
    # sends `Config.base_domain/0` to `Settings.get/1` — a DB read — for every later test
    # in the run, which fails these DB-free specs with sandbox ownership errors nowhere
    # near the test that caused them.
    setup do
      previous = Application.get_env(:homelab, :base_domain)
      Application.put_env(:homelab, :base_domain, "lab.example.com")
      on_exit(fn -> Application.put_env(:homelab, :base_domain, previous) end)
    end

    test "a host one label under the base domain asks for the wildcard, not its own cert" do
      deployment =
        build_deployment(build_tenant(), build_template(%{exposure_mode: :public}), %{
          domain: "downloads.lab.example.com"
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      r = "downloads-lab-example-com"

      assert spec.labels["traefik.http.routers.#{r}.tls.domains[0].main"] ==
               "lab.example.com"

      assert spec.labels["traefik.http.routers.#{r}.tls.domains[0].sans"] ==
               "*.lab.example.com"
    end

    # A wildcard matches exactly ONE label. Claiming `*.lab.example.com` covers
    # `a.b.lab.example.com` would point the router at a certificate that does not
    # authenticate it, and the browser — not Traefik — is what rejects that.
    test "a host two labels deep is not covered and keeps its own cert" do
      deployment =
        build_deployment(build_tenant(), build_template(%{exposure_mode: :public}), %{
          domain: "a.b.lab.example.com"
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      r = "a-b-lab-example-com"

      refute Map.has_key?(spec.labels, "traefik.http.routers.#{r}.tls.domains[0].main")
      assert spec.labels["traefik.http.routers.#{r}.tls.certresolver"] == "letsencrypt"
    end

    # `downloads.example.com` is a sibling of the base domain, not a child of it. Suffix
    # matching alone would claim it — `String.ends_with?("downloads.example.com",
    # "example.com")` is true — which is why the boundary is matched on a label, not on
    # a substring.
    test "a host outside the base domain is not covered" do
      deployment =
        build_deployment(build_tenant(), build_template(%{exposure_mode: :public}), %{
          domain: "downloads.example.com"
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      refute Map.has_key?(
               spec.labels,
               "traefik.http.routers.downloads-example-com.tls.domains[0].main"
             )
    end

    # The point of a LIST rather than just `base_domain`: nesting costs nothing. With both
    # `example.com` and `lab.example.com` held, each host lands on the one that actually
    # covers it — and because coverage is an exact one-label test, never on both.
    test "a host picks the wildcard that covers it, not merely one it is a suffix of" do
      # Seeded straight into the settings CACHE, not through `Settings.set/3`. These specs
      # run without a database checked out, and `wildcard_domains/0` reads `get_cached/2`
      # for exactly that reason — so the cache is the honest seam to drive it from.
      :ets.insert(:homelab_settings_cache, {"wildcard_domains", "*.example.com"})
      on_exit(fn -> :ets.delete(:homelab_settings_cache, "wildcard_domains") end)

      cases = [
        {"downloads.example.com", "downloads-example-com", "example.com"},
        {"downloads.lab.example.com", "downloads-lab-example-com", "lab.example.com"}
      ]

      for {domain, router, expected} <- cases do
        deployment =
          build_deployment(build_tenant(), build_template(%{exposure_mode: :public}), %{
            domain: domain
          })

        assert {:ok, spec} = SpecBuilder.build(deployment)

        assert spec.labels["traefik.http.routers.#{router}.tls.domains[0].main"] == expected,
               "#{domain} should be served off *.#{expected}"

        assert spec.labels["traefik.http.routers.#{router}.tls.domains[0].sans"] ==
                 "*.#{expected}"
      end
    end

    # An extra route is another router on the SAME host, and it carries its own
    # `certresolver`. Left alone it would order a single-name cert for a host the base
    # router is already serving off the wildcard.
    test "extra-route routers on a covered host reuse the same wildcard" do
      deployment =
        build_deployment(build_tenant(), build_template(%{exposure_mode: :public}), %{
          domain: "chat.lab.example.com",
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.routers.chat-lab-example-com-app.tls.domains[0].main"] ==
               "lab.example.com"
    end
  end

  describe "routed port (the port Traefik forwards to)" do
    # The aut.hair outage: the app exposed 8080 and listened on 8000. Both are
    # "conventional" web ports, so PortRoles.infer/1 called BOTH "web", the guess took
    # whichever came first, and Traefik was pointed at a port nothing listened on --
    # a 502 with a perfectly healthy container behind it.
    test "an explicit routed_port beats a role=web port that merely sorts first" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          ports_override: [
            %{"internal" => "8080", "role" => "web"},
            %{"internal" => "8000", "role" => "web"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.services.aut-hair.loadbalancer.server.port"] == "8000",
             "the proxy must forward to the declared port, not the first web-ish one"
    end

    test "without an explicit routed_port the old heuristic still applies" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: nil,
          ports_override: [%{"internal" => "9000", "role" => "web"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["traefik.http.services.aut-hair.loadbalancer.server.port"] == "9000"
    end

    test "the guess never lands on a UDP port, even when it sorts first" do
      # Traefik's http services speak TCP only, so a UDP port is not a lower-ranked
      # candidate for the route — it is not a candidate. A game server publishing its
      # UDP probe port ahead of its TCP listener must still route to the TCP one.
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "kbc.li",
          routed_port: nil,
          ports_override: [
            %{"internal" => "27900", "role" => "other", "protocol" => "udp"},
            %{"internal" => "18710", "role" => "other", "protocol" => "tcp"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["traefik.http.services.kbc-li.loadbalancer.server.port"] == "18710"
    end

    test "a UDP-only workload falls back to 80 rather than routing to the UDP port" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "kbc.li",
          routed_port: nil,
          ports_override: [%{"internal" => "27900", "role" => "other", "protocol" => "udp"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.services.kbc-li.loadbalancer.server.port"] == "80",
             "pointing http at 27900/udp would be a route that cannot ever answer"
    end

    # A wrong routed port must fail loudly at deploy time rather than come up
    # "healthy" and serve 502s through the proxy.
    test "an HTTP healthcheck probes the routed port, not a different guess" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :public,
          health_check: %{"path" => "/up"}
        })

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          ports_override: [
            %{"internal" => "8080", "role" => "web"},
            %{"internal" => "8000", "role" => "web"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert Enum.any?(spec.health_check["Test"], &String.contains?(&1, "localhost:8000/up"))
      refute Enum.any?(spec.health_check["Test"], &String.contains?(&1, "8080"))
    end
  end

  describe "volumes_override (durable storage a template never declared)" do
    # Volumes came from the TEMPLATE only -- build_volumes/2 never looked at the
    # deployment -- so an app needing storage its catalog entry did not declare had no way
    # to get it short of editing the shared catalog entry. aut.hair needs exactly that.
    test "a deployment can add a durable volume its template never declared" do
      tenant = build_tenant()
      template = build_template(%{volumes: [], exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          volumes_override: [%{"container_path" => "/var/www/html/storage"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert [volume] = spec.volumes

      assert volume.target == "/var/www/html/storage"

      # A NAMED volume, not a bind: that is what makes it survive the container being
      # recreated, which every config save now does.
      assert volume.type == "volume"
      assert volume.source =~ "homelab-"
    end

    # The pre-homelab stack is entirely FOLDER mounts, so a volumes editor that could only
    # produce named volumes could not express it -- or match it.
    test "a folder mount becomes a real bind, not a named volume" do
      tenant = build_tenant()
      template = build_template(%{volumes: []})

      deployment =
        build_deployment(tenant, template, %{
          volumes_override: [
            %{
              "container_path" => "/config",
              "type" => "bind",
              "source" => "/home/austin/.homelab/plex/config"
            }
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert [%{type: "bind", source: "/home/austin/.homelab/plex/config", target: "/config"}] =
               spec.volumes
    end

    # Docker reads a bare word as a NAMED VOLUME, not a path -- so a typo'd bind source does
    # not error, it silently creates an empty volume and the app comes up with no data.
    # Indistinguishable from data loss at a glance, so it must never reach the spec.
    test "a folder mount with a non-absolute host path is refused" do
      changeset =
        Homelab.Deployments.Deployment.changeset(%Homelab.Deployments.Deployment{}, %{
          tenant_id: 1,
          app_template_id: 1,
          volumes_override: [
            %{"container_path" => "/config", "type" => "bind", "source" => "plex-config"}
          ]
        })

      refute changeset.valid?

      assert {message, _} = changeset.errors[:volumes_override]
      assert message =~ "absolute host path"
    end

    # nil = inherit, [] = deliberately none. Collapsing those is what silently repointed
    # Traefik at port 80 when ports_override was hard-coded to [].
    test "nil inherits the template's volumes; [] means deliberately none" do
      tenant = build_tenant()
      template = build_template(%{volumes: [%{"container_path" => "/data"}]})

      inherited = build_deployment(tenant, template, %{volumes_override: nil})
      assert {:ok, spec} = SpecBuilder.build(inherited)
      assert [%{target: "/data"}] = spec.volumes

      none = build_deployment(tenant, template, %{volumes_override: []})
      assert {:ok, spec} = SpecBuilder.build(none)
      assert spec.volumes == []
    end
  end

  describe "extra routes (a second protocol on a second port)" do
    # aut.hair: Laravel on 8000, Reverb websockets on 6001. The browser opens
    # wss://aut.hair/app -- 443, path /app -- and the HTTP server does not speak the
    # websocket protocol, so every handshake died on 8000 until /app could be pointed
    # at 6001.
    test "a path route reaches a different container port than the app" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      # The websocket route: same host, specific path, DIFFERENT backend port.
      assert spec.labels["traefik.http.routers.aut-hair-app.rule"] ==
               "Host(`aut.hair`) && PathPrefix(`/app`)"

      assert spec.labels["traefik.http.services.aut-hair-app.loadbalancer.server.port"] == "6001"

      # ...and the app route is untouched.
      assert spec.labels["traefik.http.services.aut-hair.loadbalancer.server.port"] == "8000"
    end

    # THE trap. Traefik auto-links a router to a same-named service only while the
    # workload defines exactly ONE. Add a second and every router must name its service,
    # or Traefik rejects the whole workload -- so adding a websocket route would take
    # down the HTTP route that was already working.
    test "every router names its service, so a second route cannot break the first" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.routers.aut-hair.service"] == "aut-hair"
      assert spec.labels["traefik.http.routers.aut-hair-app.service"] == "aut-hair-app"
    end

    # The service label is emitted even with no extra routes, so that ADDING one later is
    # never the change that breaks routing.
    test "the base router names its service even when there are no extra routes" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{domain: "aut.hair", extra_routes: []})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["traefik.http.routers.aut-hair.service"] == "aut-hair"
    end

    # Traefik's default priority IS the rule length, and Host && PathPrefix is strictly
    # longer than the Host it extends -- so the specific route outranks the catch-all by
    # construction, with no priority number to keep in sync with a longer domain.
    test "the path rule is strictly longer than the host rule it must outrank" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      base = spec.labels["traefik.http.routers.aut-hair.rule"]
      path = spec.labels["traefik.http.routers.aut-hair-app.rule"]

      assert String.length(path) > String.length(base)
      refute Map.has_key?(spec.labels, "traefik.http.routers.aut-hair-app.priority")
    end

    test "a nested path becomes a valid router name" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          extra_routes: [%{"path_prefix" => "/apps/events", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.routers.aut-hair-apps-events.rule"] ==
               "Host(`aut.hair`) && PathPrefix(`/apps/events`)"
    end

    # Traefik applies middleware PER ROUTER, and an extra route is its own router. An
    # :sso_protected deployment whose /app router omits `.middlewares` therefore serves
    # that path with no forwardAuth at all — and it is worse than a leak, because the
    # PathPrefix rule is longer than the bare Host rule and Traefik ranks by rule length:
    # the UNPROTECTED router outranks the protected one it was added alongside.
    test "an sso_protected extra route is behind forwardAuth, not wide open" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :sso_protected})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      names = middlewares_on(spec.labels, "aut-hair-app")
      refute names == [], "the /app router carries no middleware — the path is unguarded"

      # A dangling reference is not a safe failure mode: Traefik rejects a router naming
      # a middleware it cannot resolve, so "protected" would silently mean "404".
      Enum.each(names, fn name ->
        assert middleware_defined?(spec.labels, name),
               "the /app router references #{name}, which nothing defines"
      end)

      assert Enum.any?(names, fn name ->
               spec.labels["traefik.http.middlewares.#{name}.forwardauth.address"] ==
                 Homelab.Config.forward_auth_address()
             end)
    end

    test "a private extra route is behind the ip allowlist, not wide open" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :private})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          routed_port: 8000,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      names = middlewares_on(spec.labels, "aut-hair-app")
      refute names == [], "the /app router carries no middleware — the path is unguarded"

      assert Enum.any?(names, fn name ->
               Map.has_key?(
                 spec.labels,
                 "traefik.http.middlewares.#{name}.ipallowlist.sourcerange"
               )
             end)
    end

    # The mirror image, so the fix cannot be "attach a middleware to everything": a
    # :public deployment has nothing to enforce, and inventing a middleware for it would
    # be a new failure mode rather than a fix.
    test "a public extra route stays open, exactly like the route it extends" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "aut.hair",
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert middlewares_on(spec.labels, "aut-hair") == []
      assert middlewares_on(spec.labels, "aut-hair-app") == []
      refute Enum.any?(Map.keys(spec.labels), &String.contains?(&1, ".middlewares."))
    end

    # Phrased over EVERY router the spec emits rather than over the one this test builds:
    # whenever the base router is guarded, no sibling router may be unguarded. A future
    # feature that emits another router — a second path, a www alias, a redirect — and
    # forgets its middlewares fails HERE, without anyone remembering to extend this file.
    test "no router the spec emits escapes the protection the base router carries" do
      for exposure <- [:sso_protected, :private] do
        tenant = build_tenant()
        template = build_template(%{exposure_mode: exposure})

        deployment =
          build_deployment(tenant, template, %{
            domain: "aut.hair",
            routed_port: 8000,
            extra_routes: [
              %{"path_prefix" => "/app", "port" => 6001},
              %{"path_prefix" => "/apps/events", "port" => 6002}
            ],
            # A host alias is another router too, so the same invariant must hold for it —
            # this is the "www alias" the comment above anticipated.
            additional_domains: [
              %{"host" => "chat.example.com"},
              %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}
            ]
          })

        assert {:ok, spec} = SpecBuilder.build(deployment)

        base = middlewares_on(spec.labels, "aut-hair")
        refute base == [], "#{exposure} base router lost its middleware"

        for router <- router_names(spec.labels) do
          refute middlewares_on(spec.labels, router) == [],
                 "#{exposure}: router #{router} reaches the container with no middleware, " <>
                   "while the base router requires #{Enum.join(base, ",")}"
        end
      end
    end
  end

  describe "one host per router" do
    setup do
      previous = Application.get_env(:homelab, :base_domain)
      Application.put_env(:homelab, :base_domain, "communication.ventures")
      on_exit(fn -> Application.put_env(:homelab, :base_domain, previous) end)
    end

    # The shape of the original failure, rebuilt from the far side: a root domain and a
    # matrix subdomain, stored the way the schema now stores them, must reach Traefik as
    # TWO routers with one host each -- never as one router naming both.
    test "a root domain and its subdomain become two routers, one host each" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "communication.ventures",
          routed_port: 8008,
          additional_domains: [%{"host" => "matrix.communication.ventures"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      rules = host_rules(spec.labels)

      assert "Host(`communication.ventures`)" in rules
      assert "Host(`matrix.communication.ventures`)" in rules
    end

    # The invariant, over every routing feature at once. Any future path route, host
    # alias or redirect that lets a multi-host value through fails here.
    test "no rule the spec emits ever names more than one host" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :sso_protected})

      deployment =
        build_deployment(tenant, template, %{
          domain: "communication.ventures",
          routed_port: 8008,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}],
          additional_domains: [
            %{"host" => "matrix.communication.ventures"},
            %{"host" => "ntfy.communication.ventures", "port" => 80},
            %{"host" => "communication.ventures", "path_prefix" => "/.well-known/matrix"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      for rule <- host_rules(spec.labels) do
        [_, hosts] = Regex.run(~r/Host\(`([^`]*)`\)/, rule)

        refute String.contains?(hosts, ","),
               "rule #{rule} names several hosts in one Host() -- Traefik cannot build it " <>
                 "and Let's Encrypt will not issue for it"

        assert Hostname.valid?(hosts), "rule #{rule} does not name a routable host"
      end
    end

    # Each host must get its OWN router, or the second one is silently unrouted rather
    # than merely misrouted.
    test "each distinct host contributes a router" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "communication.ventures",
          routed_port: 8008,
          additional_domains: [
            %{"host" => "matrix.communication.ventures"},
            %{"host" => "ntfy.communication.ventures"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      hosts =
        spec.labels
        |> host_rules()
        |> Enum.map(fn rule ->
          [_, host] = Regex.run(~r/Host\(`([^`]*)`\)/, rule)
          host
        end)
        |> Enum.uniq()
        |> Enum.sort()

      assert hosts == [
               "communication.ventures",
               "matrix.communication.ventures",
               "ntfy.communication.ventures"
             ]
    end
  end

  describe "additional domains (a second host on one container)" do
    # base_domain drives wildcard-cert reuse; pinned via app-env so these DB-free specs
    # never fall through Config.base_domain/0 to a Settings DB read. Same setup, same
    # reason, as the "wildcard certificate reuse" describe.
    setup do
      previous = Application.get_env(:homelab, :base_domain)
      Application.put_env(:homelab, :base_domain, "example.com")
      on_exit(fn -> Application.put_env(:homelab, :base_domain, previous) end)
    end

    # Synapse is the motivating case: the homeserver answers on matrix.example.com. A second
    # host with no path reaches the whole container on the deployment's routed port.
    test "a second host routes to the same container on the routed port" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          routed_port: 8008,
          additional_domains: [%{"host" => "chat.example.com"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.routers.chat-example-com.rule"] ==
               "Host(`chat.example.com`)"

      # No explicit port on the entry, so it reuses the deployment's routed port.
      assert spec.labels["traefik.http.services.chat-example-com.loadbalancer.server.port"] ==
               "8008"
    end

    # THE Synapse shape: the apex serves ONLY /.well-known/matrix/*, so the rest of
    # example.com stays free for a website. Host && PathPrefix, exactly like an extra route.
    test "a path-scoped host serves only that path, leaving the rest of the host free" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          routed_port: 8008,
          additional_domains: [
            %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      r = "example-com-well-known-matrix"

      assert spec.labels["traefik.http.routers.#{r}.rule"] ==
               "Host(`example.com`) && PathPrefix(`/.well-known/matrix`)"

      assert spec.labels["traefik.http.services.#{r}.loadbalancer.server.port"] == "8008"
    end

    # The gluetun case: an alias can name a DISTINCT backend port -- a sibling app sharing
    # the donor's network namespace -- rather than the deployment's routed port.
    test "a host can target a distinct backend port" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          routed_port: 8008,
          additional_domains: [%{"host" => "sonarr.example.com", "port" => 8989}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.services.sonarr-example-com.loadbalancer.server.port"] ==
               "8989"
    end

    # The same trap extra routes hit: a second router with no explicit service makes Traefik
    # reject the whole workload, taking the base route down with it.
    test "every additional-domain router names its own service" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          additional_domains: [%{"host" => "chat.example.com"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.labels["traefik.http.routers.chat-example-com.service"] == "chat-example-com"
    end

    # The same host listed with two paths must not collapse to one router -- the path is
    # part of the router name, so both survive.
    test "the same host with two paths yields two distinct routers" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          additional_domains: [
            %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"},
            %{"host" => "example.com", "path_prefix" => "/.well-known/openid-configuration"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.labels["traefik.http.routers.example-com-well-known-matrix.rule"] ==
               "Host(`example.com`) && PathPrefix(`/.well-known/matrix`)"

      assert spec.labels[
               "traefik.http.routers.example-com-well-known-openid-configuration.rule"
             ] ==
               "Host(`example.com`) && PathPrefix(`/.well-known/openid-configuration`)"
    end

    # The apex is the `main` name on the plane's wildcard cert, NOT a child of it. Without
    # the apex branch in covered_by_wildcard?/2, an apex router carries certresolver with no
    # tls.domains and orders a redundant single-name cert for a name the wildcard authenticates.
    test "the apex host reuses the wildcard cert instead of ordering its own" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          additional_domains: [
            %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}
          ]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      r = "example-com-well-known-matrix"

      assert spec.labels["traefik.http.routers.#{r}.tls.domains[0].main"] == "example.com"
      assert spec.labels["traefik.http.routers.#{r}.tls.domains[0].sans"] == "*.example.com"
    end

    # A blank host is dropped, not turned into an unroutable `Host()` -- the mirror of a
    # half-filled extra route being ignored.
    test "an entry with a blank host emits no router" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :public})

      deployment =
        build_deployment(tenant, template, %{
          domain: "matrix.example.com",
          additional_domains: [%{"host" => "", "path_prefix" => "/x"}]
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)

      refute Enum.any?(Map.values(spec.labels), &String.contains?(&1, "/x"))
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

      assert spec.ports == [
               %{internal: "8080", external: "9090", role: "web", protocol: "tcp", host_ip: nil}
             ]
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

      assert spec.ports == [
               %{internal: "1000", external: "1000", role: "web", protocol: "tcp", host_ip: nil}
             ]
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

      assert spec.ports == [
               %{internal: "8080", external: "8080", role: "web", protocol: "tcp", host_ip: nil}
             ]

      refute spec.labels["traefik.enable"]
    end

    test ":host carries each port's protocol through to the spec" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :host,
          ports: [
            %{
              "internal" => "27900",
              "external" => "27900",
              "published" => true,
              "role" => "other",
              "protocol" => "udp"
            },
            # No "protocol" key at all — every template seeded before UDP support.
            %{
              "internal" => "18710",
              "external" => "18710",
              "published" => true,
              "role" => "other"
            }
          ]
        })

      deployment = build_deployment(tenant, template, %{})

      assert {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.ports == [
               %{
                 internal: "27900",
                 external: "27900",
                 role: "other",
                 protocol: "udp",
                 host_ip: nil
               },
               %{
                 internal: "18710",
                 external: "18710",
                 role: "other",
                 protocol: "tcp",
                 host_ip: nil
               }
             ]
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

  describe "kernel privileges" do
    test "the template's privileges reach the spec when no override is set" do
      tenant = build_tenant()

      template =
        build_template(%{
          capabilities_add: ["NET_ADMIN"],
          capabilities_drop: ["ALL"],
          devices: [%{"host_path" => "/dev/net/tun", "container_path" => "/dev/net/tun"}],
          sysctls: %{"net.ipv4.conf.all.src_valid_mark" => "1"}
        })

      deployment = build_deployment(tenant, template)

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.capabilities_add == ["NET_ADMIN"]
      assert spec.capabilities_drop == ["ALL"]
      assert [%{"host_path" => "/dev/net/tun", "permissions" => "rwm"}] = spec.devices
      assert spec.sysctls == %{"net.ipv4.conf.all.src_valid_mark" => "1"}
    end

    test "an override WINS, and [] is a real override rather than 'inherit'" do
      # Explicitly dropping the capability a shared template grants is a hardening
      # instruction. Treating [] as absent would silently keep granting it.
      tenant = build_tenant()
      template = build_template(%{capabilities_add: ["NET_ADMIN", "SYS_MODULE"]})

      deployment =
        build_deployment(tenant, template, %{capabilities_add_override: ["NET_BIND_SERVICE"]})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.capabilities_add == ["NET_BIND_SERVICE"]

      cleared = build_deployment(tenant, template, %{capabilities_add_override: []})
      assert {:ok, cleared_spec} = SpecBuilder.build(cleared)
      assert cleared_spec.capabilities_add == []
    end

    test "the two spellings of one capability are folded before the drivers see them" do
      tenant = build_tenant()
      template = build_template(%{capabilities_add: ["CAP_NET_ADMIN"]})
      deployment = build_deployment(tenant, template, %{capabilities_add_override: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.capabilities_add == ["NET_ADMIN"]
    end

    test "a deployment with none of them gets empty values, never nil" do
      tenant = build_tenant()
      deployment = build_deployment(tenant, build_template())

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.capabilities_add == []
      assert spec.capabilities_drop == []
      assert spec.devices == []
      assert spec.sysctls == %{}
    end
  end

  # The spec a host-network deployment produces is defined as much by what it OMITS as
  # by the network name: aliases, port bindings and a routing label are each rejected by
  # the daemon next to host networking, not ignored, so emitting one fails the deploy.
  describe "host network access" do
    test "the container is placed in the host's namespace instead of the tenant network" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :host_network})
      deployment = build_deployment(tenant, template, %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.network == "host"
      assert spec.host_network == true
      refute spec.network =~ "homelab_tenant_"
    end

    test "nothing is published — the container already listens on the host's ports" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :host_network, ports: host_ports()})
      deployment = build_deployment(tenant, template, %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.ports == []
    end

    test "network aliases are dropped — there is no embedded DNS to register them in" do
      tenant = build_tenant()

      template =
        build_template(%{exposure_mode: :host_network, network_aliases: ["mysql", "db"]})

      deployment = build_deployment(tenant, template, %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.network_aliases == []
    end

    test "a stray domain still produces no Traefik route — there is no backend IP to route to" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :host_network, ports: host_ports()})
      deployment = build_deployment(tenant, template, %{domain: "app.friends.test"})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      refute spec.labels["traefik.enable"]
      assert spec.labels["homelab.exposure"] == "host_network"
      refute spec.service_mode
    end

    test "the healthcheck still probes the app's port (localhost IS the host here)" do
      tenant = build_tenant()

      template =
        build_template(%{
          exposure_mode: :host_network,
          ports: host_ports(),
          health_check: %{"path" => "/healthz"}
        })

      deployment = build_deployment(tenant, template, %{routed_port: 8080, domain: nil})

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert [_cmd_shell, probe] = spec.health_check["Test"]
      assert probe =~ "http://localhost:8080/healthz"
    end

    test "a per-deployment override can put an otherwise-proxied app on the host network" do
      tenant = build_tenant()
      template = build_template(%{exposure_mode: :sso_protected, ports: host_ports()})

      deployment =
        build_deployment(tenant, template, %{
          exposure_mode_override: "host_network",
          domain: "app.friends.test"
        })

      assert {:ok, spec} = SpecBuilder.build(deployment)
      assert spec.network == "host"
      assert spec.host_network == true
      assert spec.ports == []
      refute spec.labels["traefik.enable"]
    end

    test "every other access mode leaves host_network false" do
      tenant = build_tenant()

      for mode <- [:public, :sso_protected, :private, :host, :service] do
        deployment =
          build_deployment(tenant, build_template(%{exposure_mode: mode}), %{domain: nil})

        assert {:ok, spec} = SpecBuilder.build(deployment)
        refute spec.host_network, "#{mode} must not be on the host network"
        assert spec.network =~ "homelab_tenant_"
      end
    end
  end

  describe "GPU" do
    test "no GPU by default" do
      tenant = build_tenant()
      template = build_template()
      {:ok, spec} = SpecBuilder.build(build_deployment(tenant, template))

      assert spec.gpu == nil
      refute Map.has_key?(spec.env, "NVIDIA_VISIBLE_DEVICES")
    end

    test "a GPU request rides in resource_limits — no migration needed" do
      tenant = build_tenant()

      template =
        build_template(%{
          resource_limits: %{
            "memory_mb" => 512,
            "cpu_shares" => 1024,
            "gpu" => %{"vendor" => "nvidia"}
          }
        })

      {:ok, spec} = SpecBuilder.build(build_deployment(tenant, template))

      assert spec.gpu.vendor == "nvidia"
      assert spec.gpu.kind == "NVIDIA-GPU"
      # Memory/CPU still flow — the GPU key rides alongside them, it does not replace them.
      assert spec.memory_limit == 512 * 1_048_576
    end

    # Under Swarm this env var is the ONLY thing that puts a device in the container: the
    # generic-resource reservation just picks the node. Without it the task schedules onto
    # kratos and starts, with no GPU inside — which surfaces hours later as an inference
    # error and looks like a broken image.
    test "sets the vendor's visible-devices var, which is what the runtime hook reads" do
      tenant = build_tenant()

      template =
        build_template(%{resource_limits: %{"gpu" => %{"vendor" => "nvidia", "devices" => "0"}}})

      {:ok, spec} = SpecBuilder.build(build_deployment(tenant, template))

      assert spec.env["NVIDIA_VISIBLE_DEVICES"] == "0"
    end

    test "amd gets its own var" do
      tenant = build_tenant()
      template = build_template(%{resource_limits: %{"gpu" => %{"vendor" => "amd"}}})

      {:ok, spec} = SpecBuilder.build(build_deployment(tenant, template))

      assert spec.env["AMD_VISIBLE_DEVICES"] == "all"
    end

    test "an operator's env override still wins — we never clobber a hand-pinned device" do
      tenant = build_tenant()
      template = build_template(%{resource_limits: %{"gpu" => %{"vendor" => "nvidia"}}})

      deployment =
        build_deployment(tenant, template, %{
          env_overrides: %{"NVIDIA_VISIBLE_DEVICES" => "GPU-45cbf7b3"}
        })

      {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.env["NVIDIA_VISIBLE_DEVICES"] == "GPU-45cbf7b3"
    end

    test "a deployment override can add a GPU the template never asked for" do
      tenant = build_tenant()
      template = build_template()

      deployment =
        build_deployment(tenant, template, %{
          resource_limits_override: %{"memory_mb" => 2048, "gpu" => %{"vendor" => "amd"}}
        })

      {:ok, spec} = SpecBuilder.build(deployment)

      assert spec.gpu.vendor == "amd"
      assert spec.memory_limit == 2048 * 1_048_576
    end
  end

  # Every router NAME the label map mentions, discovered rather than listed, so an
  # assertion can be written about routers a test never named.
  # "traefik.http.routers.aut-hair-app.rule" -> "aut-hair-app".
  # A regression guard on the SHAPE of every rule the spec emits, not on one known-bad
  # value. `communication.ventures,matrix.communication.ventures` reached Traefik as a
  # single ``Host(`a,b`)`` and cost a router that would not build and an ACME order
  # Let's Encrypt refused -- and nothing in this file would have noticed, because every
  # test asserted on the rules it expected rather than on the rules that exist.
  defp host_rules(labels) do
    labels
    |> Enum.flat_map(fn
      {"traefik.http.routers." <> rest, rule} ->
        if String.ends_with?(rest, ".rule"), do: [rule], else: []

      _ ->
        []
    end)
  end

  defp router_names(labels) do
    labels
    |> Map.keys()
    |> Enum.flat_map(fn key ->
      case String.split(key, ".") do
        ["traefik", "http", "routers", name | _] -> [name]
        _ -> []
      end
    end)
    |> Enum.uniq()
  end

  # Traefik reads `.middlewares` as a comma-joined LIST, so it is compared as a set of
  # names and never as the one string that happens to be there today.
  defp middlewares_on(labels, router) do
    labels
    |> Map.get("traefik.http.routers.#{router}.middlewares", "")
    |> String.split(",", trim: true)
  end

  defp middleware_defined?(labels, name) do
    Enum.any?(Map.keys(labels), &String.starts_with?(&1, "traefik.http.middlewares.#{name}."))
  end
end
