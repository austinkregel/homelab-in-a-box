defmodule Homelab.Deployments.IngressPublishTest do
  @moduledoc """
  Which workloads may be attached to the ingress network, and on which network.

  `publish`/`unpublish` attach and detach the WORKLOAD rather than connecting Traefik to
  a per-deployment network nothing was ever on. Two things that model has to get right:

    * a container in ANOTHER container's network namespace has no endpoint of its own,
      and the daemon rejects `/networks/<n>/connect` on it outright. Its route is served
      by its donor, which is multi-homed onto ingress at create time.
    * the network is not a constant. It is whatever the workload's
      `traefik.docker.network` label names, so it is passed rather than assumed.
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory
  import Mox

  alias Homelab.Deployments

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    tenant = insert(:tenant)

    donor =
      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, name: "Gluetun", slug: "gluetun", ports: []),
        domain: nil,
        status: :running,
        external_id: "gluetun-1"
      )

    %{tenant: tenant, donor: donor}
  end

  defp tunneled_child(tenant, donor) do
    insert(:deployment,
      tenant: tenant,
      app_template:
        insert(:app_template,
          name: "Sonarr",
          slug: "sonarr",
          exposure_mode: :public,
          ports: [%{"internal" => 8989, "role" => "web"}]
        ),
      domain: "sonarr.example.com",
      network_parent_id: donor.id,
      status: :running,
      external_id: "sonarr-1"
    )
  end

  test "a tunneled child is NEVER attached to ingress", ctx do
    # It is proxy-mode WITH a domain, so it looks ingress-published by every other
    # measure — but it has no endpoint to attach. The daemon answers 403 ("container
    # sharing network namespace with another container or host cannot be connected to
    # any other network"), which would fail the release's publish step and roll the
    # whole deploy back.
    child = tunneled_child(ctx.tenant, ctx.donor)

    # No orchestrator expectation: any call at all is a failure here.
    assert :ok = Deployments.publish_deployment(child)
    assert :ok = Deployments.unpublish_deployment(child)
  end

  test "an ordinary routed deployment IS attached, on the ingress network", ctx do
    deployment =
      insert(:deployment,
        tenant: ctx.tenant,
        app_template: insert(:app_template, slug: "blog", exposure_mode: :public),
        domain: "blog.example.com",
        status: :running,
        external_id: "blog-1"
      )

    ingress = Homelab.Infrastructure.internal_network()

    Homelab.Mocks.Orchestrator
    |> expect(:publish, fn "blog-1", ^ingress -> :ok end)
    |> expect(:unpublish, fn "blog-1", ^ingress -> :ok end)

    assert :ok = Deployments.publish_deployment(deployment)
    assert :ok = Deployments.unpublish_deployment(deployment)
  end

  test "detaching from ingress leaves the workload's other networks alone", ctx do
    # A routed workload is multi-homed: its private tenant network plus ingress. Severing
    # its public route must not cut it off from its own datastores.
    deployment =
      insert(:deployment,
        tenant: ctx.tenant,
        app_template: insert(:app_template, slug: "app2", exposure_mode: :public),
        domain: "app2.example.com",
        status: :running,
        external_id: "app2-1"
      )

    ingress = Homelab.Infrastructure.internal_network()

    Homelab.Mocks.Orchestrator
    |> expect(:unpublish, fn "app2-1", network ->
      assert network == ingress
      refute network =~ "tenant"
      :ok
    end)

    assert :ok = Deployments.unpublish_deployment(deployment)
  end
end
