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

  defp routed_labels(orchestrator) do
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
      ports: [%{"container" => 8080, "protocol" => "tcp"}],
      resource_limits: %{"memory_mb" => 512, "cpu_shares" => 1024},
      backup_policy: %{},
      health_check: %{},
      depends_on: []
    }

    deployment = %Homelab.Deployments.Deployment{
      id: 1,
      tenant: tenant,
      tenant_id: tenant.id,
      app_template: template,
      app_template_id: template.id,
      status: :pending,
      env_overrides: %{},
      domain: "nextcloud.friends.homelab.local"
    }

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
end
