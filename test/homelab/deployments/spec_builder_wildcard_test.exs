defmodule Homelab.Deployments.SpecBuilderWildcardTest do
  @moduledoc """
  Which certificate a router is told to serve — split out of `SpecBuilderTest` because
  these specs drive `Config.wildcard_domains/0`, and its only seam is a GLOBAL one.

  `wildcard_domains/0` reads the `:homelab_settings_cache` ETS table, which is not per
  test and does not roll back. `DataCase`'s setup calls `Settings.reset_cache/0` —
  `:ets.delete_all_objects/1` over that same table — so every async DataCase test wipes
  it, including while another async module is mid-test. Seeded from an `async: true`
  module, `wildcard_domains` could vanish between the `:ets.insert` and the assertion,
  and the run failed claiming `downloads.example.com` was not served off `*.example.com`
  — a real race with a message that reads like a routing bug.

  `async: false` is the fix, and it has to be the whole module rather than the one test
  that seeds: sync modules run after every async one has finished, so nothing is left to
  wipe the table underneath them. The tests that assert the ABSENCE of coverage travel
  with it — they read the same global and are the ones a leaked value would break.
  """
  use ExUnit.Case, async: false

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

  defp build_template(overrides) do
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

  defp build_deployment(tenant, template, overrides) do
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
end
