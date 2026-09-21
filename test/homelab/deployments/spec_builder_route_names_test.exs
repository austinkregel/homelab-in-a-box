defmodule Homelab.Deployments.SpecBuilderRouteNamesTest do
  @moduledoc """
  `route_names/1` exists so a reader of Traefik's metrics can ask about a deployment
  by the same names the deployment's own labels wrote.

  The traffic tab used to derive one name itself, by lower-casing the domain and
  swapping dots for dashes. That reproduced the BASE router and nothing else, so a
  deployment answering on a second host reported only part of its traffic — and the
  derivation was free to drift from the label builder it was imitating.

  Every test here pins the two together: whatever `route_names/1` returns must appear
  as a real `traefik.http.routers.<name>.rule` key in the built spec.
  """
  # async: false — reads the global :orchestrator application env.
  use ExUnit.Case, async: false

  alias Homelab.Deployments.SpecBuilder

  setup do
    prev = Application.get_env(:homelab, :orchestrator)
    Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerEngine)
    on_exit(fn -> Application.put_env(:homelab, :orchestrator, prev) end)
    :ok
  end

  defp deployment(overrides \\ []) do
    template = %Homelab.Catalog.AppTemplate{
      id: 1,
      slug: "synapse",
      name: "Synapse",
      version: "1.0",
      image: "synapse:1.0",
      exposure_mode: :public,
      auth_integration: false,
      default_env: %{},
      required_env: [],
      volumes: [],
      ports: [%{"internal" => 8008, "role" => "web", "protocol" => "tcp"}],
      resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
      backup_policy: %{},
      health_check: %{},
      depends_on: []
    }

    tenant = %Homelab.Tenants.Tenant{
      id: 1,
      slug: "home",
      name: "Home",
      status: :active,
      settings: %{}
    }

    struct(
      %Homelab.Deployments.Deployment{
        id: 1,
        network_children: [],
        secrets: [],
        tenant: tenant,
        tenant_id: tenant.id,
        app_template: template,
        app_template_id: template.id,
        status: :running,
        env_overrides: %{},
        proxy_options: %{},
        extra_routes: [],
        additional_domains: [],
        domain: "matrix.example.com"
      },
      overrides
    )
  end

  defp router_names_in_labels(deployment) do
    {:ok, spec} = SpecBuilder.build(deployment)

    spec.labels
    |> Map.keys()
    |> Enum.filter(&String.ends_with?(&1, ".rule"))
    |> Enum.map(fn key ->
      key
      |> String.replace_prefix("traefik.http.routers.", "")
      |> String.replace_suffix(".rule", "")
    end)
    |> MapSet.new()
  end

  test "the primary host is named exactly as the base router is" do
    deployment = deployment()

    assert [%{name: "matrix-example-com", host: "matrix.example.com", path: nil, kind: :primary}] =
             SpecBuilder.route_names(deployment)
  end

  test "an additional domain contributes a router of its own" do
    deployment =
      deployment(
        additional_domains: [
          %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}
        ]
      )

    names = Enum.map(SpecBuilder.route_names(deployment), & &1.name)

    assert names == ["matrix-example-com", "example-com-well-known-matrix"]
  end

  test "an extra path route contributes a router of its own" do
    deployment = deployment(extra_routes: [%{"path_prefix" => "/app", "port" => 6001}])

    assert Enum.map(SpecBuilder.route_names(deployment), & &1.name) ==
             ["matrix-example-com", "matrix-example-com-app"]
  end

  test "every name returned is a router the spec actually defines" do
    deployment =
      deployment(
        extra_routes: [%{"path_prefix" => "/app", "port" => 6001}],
        additional_domains: [
          %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"},
          %{"host" => "chat.example.com"}
        ]
      )

    emitted = router_names_in_labels(deployment)
    named = SpecBuilder.route_names(deployment)

    # Neither direction may drift: a name the UI asks about that no router defines
    # reports a live app as idle, and a router the UI never asks about loses its
    # traffic silently.
    assert MapSet.new(named, & &1.name) == emitted
    assert length(named) == 4
  end

  test "each entry carries the host and path its router answers on" do
    deployment =
      deployment(
        extra_routes: [%{"path_prefix" => "/app", "port" => 6001}],
        additional_domains: [%{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}]
      )

    assert SpecBuilder.route_names(deployment) == [
             %{
               name: "matrix-example-com",
               host: "matrix.example.com",
               path: nil,
               kind: :primary
             },
             %{
               name: "matrix-example-com-app",
               host: "matrix.example.com",
               path: "/app",
               kind: :path
             },
             %{
               name: "example-com-well-known-matrix",
               host: "example.com",
               path: "/.well-known/matrix",
               kind: :host
             }
           ]
  end

  test "a deployment with no domain has no routers to meter" do
    assert SpecBuilder.route_names(deployment(domain: nil)) == []
    assert SpecBuilder.route_names(deployment(domain: "")) == []
  end

  test "a non-proxied deployment has none either, even carrying a stray domain" do
    # `build_routing_labels/2` emits nothing for these modes, so asking Traefik about
    # them would be asking about a router that does not exist.
    for mode <- [:host, :internal] do
      deployment = deployment(exposure_mode_override: to_string(mode))

      assert SpecBuilder.route_names(deployment) == [],
             "expected no routers for #{mode} exposure"
    end
  end

  test "malformed extra routes and additional domains are skipped, not named" do
    deployment =
      deployment(
        extra_routes: [%{"path_prefix" => "/app"}, %{"port" => 1234}],
        additional_domains: [%{"host" => ""}, %{"path_prefix" => "/x"}]
      )

    assert Enum.map(SpecBuilder.route_names(deployment), & &1.name) == ["matrix-example-com"]
  end
end
