defmodule Homelab.Deployments.SpecBuilderRoutingTest do
  @moduledoc """
  Traefik's network label is provider-specific, and the two forms are mutually
  exclusive: a workload carrying BOTH `traefik.docker.network` and
  `traefik.swarm.network` is rejected by Traefik ("both Docker and Swarm labels are
  defined") and skipped entirely, leaving the app unrouted.
  """
  # async: false — mutates the global :orchestrator application env.
  use ExUnit.Case, async: false

  alias Homelab.Deployments.SpecBuilder

  @docker_label "traefik.docker.network"
  @swarm_label "traefik.swarm.network"

  setup do
    prev = Application.get_env(:homelab, :orchestrator)
    on_exit(fn -> Application.put_env(:homelab, :orchestrator, prev) end)
    :ok
  end

  defp routed_labels(orchestrator, overrides \\ []) do
    Application.put_env(:homelab, :orchestrator, orchestrator)

    tenant = %Homelab.Tenants.Tenant{
      id: 1,
      slug: "friends",
      name: "Friends",
      status: :active,
      settings: %{}
    }

    template = %Homelab.Catalog.AppTemplate{
      id: 1,
      slug: "nextcloud",
      name: "Nextcloud",
      version: "28.0",
      image: "nextcloud:28.0",
      exposure_mode: :public,
      auth_integration: false,
      default_env: %{},
      required_env: [],
      volumes: [],
      ports: [%{"internal" => 8080, "role" => "web", "protocol" => "tcp"}],
      resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
      backup_policy: %{},
      health_check: %{},
      depends_on: []
    }

    deployment =
      struct(
        %Homelab.Deployments.Deployment{
          id: 1,
          tenant: tenant,
          tenant_id: tenant.id,
          app_template: template,
          app_template_id: template.id,
          status: :pending,
          env_overrides: %{},
          proxy_options: %{},
          domain: "nextcloud.friends.homelab.local"
        },
        overrides
      )

    {:ok, spec} = SpecBuilder.build(deployment)
    spec.labels
  end

  test "a Swarm service gets the swarm network label ONLY" do
    labels = routed_labels(Homelab.Orchestrators.DockerSwarm)

    assert labels["traefik.enable"] == "true"
    assert labels[@swarm_label] == "homelab-iab-internal"

    # Emitting both does not make Traefik pick one — it skips the workload.
    refute Map.has_key?(labels, @docker_label)
  end

  test "a plain container gets the docker network label ONLY" do
    labels = routed_labels(Homelab.Orchestrators.DockerEngine)

    assert labels["traefik.enable"] == "true"
    assert labels[@docker_label] == "homelab-iab-internal"
    refute Map.has_key?(labels, @swarm_label)
  end

  describe "the port the proxy forwards to" do
    @port_label "traefik.http.services.nextcloud-friends-homelab-local.loadbalancer.server.port"

    test "an EMPTY ports_override must not silently repoint the proxy at port 80" do
      # Access.effective_ports/1 only inherits the template on nil, so `[]` is a real
      # override — and primary_port([]) falls back to "80". The Settings form hard-coded
      # `[]` for every proxy deployment, so merely opening Settings and saving repointed
      # Traefik away from the port the app actually listens on.
      labels = routed_labels(Homelab.Orchestrators.DockerSwarm, ports_override: nil)

      assert labels[@port_label] == "8080"
      refute labels[@port_label] == "80"
    end

    test "the port carrying role=web is the one forwarded to" do
      labels =
        routed_labels(Homelab.Orchestrators.DockerSwarm,
          ports_override: [
            %{"internal" => 9090, "role" => "metrics"},
            %{"internal" => 4000, "role" => "web"}
          ]
        )

      # Not the first port — the designated one. An app on a non-conventional port is
      # exactly where inferring the role from the port number gets it wrong.
      assert labels[@port_label] == "4000"
    end
  end

  describe "sticky sessions" do
    @sticky "traefik.http.services.nextcloud-friends-homelab-local.loadbalancer.sticky.cookie"

    test "off by default" do
      refute Map.has_key?(routed_labels(Homelab.Orchestrators.DockerSwarm), @sticky)
    end

    test "on when the deployment opts in — what keeps a websocket on one replica" do
      labels =
        routed_labels(Homelab.Orchestrators.DockerSwarm, proxy_options: %{"sticky" => true})

      assert labels[@sticky] == "true"
      assert labels[@sticky <> ".secure"] == "true"
    end
  end
end
