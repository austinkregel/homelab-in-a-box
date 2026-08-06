defmodule Homelab.Deployments.NetnsTest do
  @moduledoc """
  Sharing one network namespace between deployments — `network_mode: service:gluetun`.

  Every rule here exists because the failure it prevents is SILENT: the daemon rejects
  some of these with a message naming a flag the operator never typed, and simply does
  the wrong thing with the rest. A tunneled app that comes up outside the tunnel reports
  a successful deploy and leaks from the first second.
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{Netns, SpecBuilder}
  alias Homelab.Repo

  setup do
    tenant = insert(:tenant)

    donor_template =
      insert(:app_template,
        name: "Gluetun",
        slug: "gluetun",
        ports: [%{"internal" => 8000, "role" => "other"}],
        netns_donor_kind: "gluetun",
        exposure_mode: :service
      )

    donor =
      insert(:deployment,
        tenant: tenant,
        app_template: donor_template,
        domain: nil,
        status: :running,
        external_id: "gluetun-container-1"
      )

    %{tenant: tenant, donor: donor}
  end

  defp child_attrs(tenant, donor, overrides \\ %{}) do
    template =
      insert(:app_template,
        name: "Sonarr #{System.unique_integer([:positive])}",
        slug: "sonarr-#{System.unique_integer([:positive])}",
        ports: [%{"internal" => 8989, "role" => "web"}],
        exposure_mode: :public
      )

    Map.merge(
      %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        network_parent_id: donor.id,
        domain: "sonarr.example.com"
      },
      overrides
    )
  end

  describe "what a child gives up" do
    test "host ports are refused — it has none of its own to bind", ctx do
      attrs = child_attrs(ctx.tenant, ctx.donor, %{exposure_mode_override: "host"})

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "no ports of its own"
    end

    test "host networking is refused — a container has ONE network namespace", ctx do
      attrs = child_attrs(ctx.tenant, ctx.donor, %{exposure_mode_override: "host_network"})

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "one network namespace"
    end

    test "network aliases are refused — there is no endpoint to register a name on", ctx do
      attrs = child_attrs(ctx.tenant, ctx.donor, %{network_aliases_override: ["sonarr"]})

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_aliases_override: [message]} = errors_on(changeset)
      assert message =~ "no network endpoint"
    end
  end

  describe "structural rules" do
    test "the donor must be in the same space", ctx do
      other_tenant = insert(:tenant)
      attrs = child_attrs(other_tenant, ctx.donor)

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "same space"
    end

    test "chains are refused — one donor, N children, no grandchildren", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      attrs = child_attrs(ctx.tenant, child, %{domain: "grandchild.example.com"})

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "chains are not supported"
    end

    test "a deployment cannot route through itself", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      assert {:error, changeset} =
               Deployments.update_deployment(child, %{network_parent_id: child.id})

      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "itself"
    end

    test "a donor that is itself host-networked has no namespace to share", ctx do
      host_template = insert(:app_template, slug: "hass", exposure_mode: :host_network)

      host_donor =
        insert(:deployment,
          tenant: ctx.tenant,
          app_template: host_template,
          domain: nil,
          exposure_mode_override: "host_network"
        )

      assert {:error, changeset} =
               Deployments.create_deployment(child_attrs(ctx.tenant, host_donor))

      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "host networking"
    end

    test "Docker Swarm is refused where the choice is made", ctx do
      previous = Application.get_env(:homelab, :orchestrator)
      Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerSwarm)
      on_exit(fn -> Application.put_env(:homelab, :orchestrator, previous) end)

      assert {:error, changeset} =
               Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "Docker Engine"
    end
  end

  # Children of one donor share a single localhost. Two apps both on 8080 is not a
  # preference conflict: the second to start fails to bind, and which one that is
  # depends on scheduling — so the stack works until it does not.
  describe "sibling port collisions" do
    test "two children cannot claim the same port", ctx do
      {:ok, _first} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      colliding =
        insert(:app_template,
          name: "Radarr",
          slug: "radarr",
          ports: [%{"internal" => 8989, "role" => "web"}]
        )

      attrs =
        child_attrs(ctx.tenant, ctx.donor, %{
          app_template_id: colliding.id,
          domain: "radarr.example.com"
        })

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "8989"
    end

    test "a child cannot claim a port the DONOR already listens on", ctx do
      # gluetun's control server is on 8000 and is in the same namespace.
      colliding = insert(:app_template, slug: "ctl", ports: [%{"internal" => 8000}])

      attrs =
        child_attrs(ctx.tenant, ctx.donor, %{
          app_template_id: colliding.id,
          domain: "ctl.example.com"
        })

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "8000"
    end

    test "distinct ports are fine", ctx do
      {:ok, _first} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      radarr =
        insert(:app_template, name: "Radarr", slug: "radarr", ports: [%{"internal" => 7878}])

      attrs =
        child_attrs(ctx.tenant, ctx.donor, %{
          app_template_id: radarr.id,
          domain: "radarr.example.com"
        })

      assert {:ok, _second} = Deployments.create_deployment(attrs)
    end
  end

  describe "the spec a child produces" do
    setup ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))
      Map.put(ctx, :child, Deployments.get_deployment!(child.id))
    end

    test "joins the donor's namespace by CONTAINER id", ctx do
      assert {:ok, spec} = SpecBuilder.build(ctx.child)

      assert spec.network == "container:gluetun-container-1"
      assert spec.netns_child == true
      refute spec.network =~ "homelab_tenant_"
    end

    test "publishes nothing and registers no name — the daemon rejects both here", ctx do
      assert {:ok, spec} = SpecBuilder.build(ctx.child)

      assert spec.ports == []
      assert spec.network_aliases == []
      assert spec.bridge_networks == []
    end

    test "emits NO Traefik labels of its own — it has no endpoint to resolve to", ctx do
      assert {:ok, spec} = SpecBuilder.build(ctx.child)

      refute Map.has_key?(spec.labels, "traefik.enable")
    end

    test "refuses to build while the donor has no container", ctx do
      # A create naming a container id that does not exist yields a container the daemon
      # will never start, with an error pointing at the wrong thing.
      {:ok, _} = Deployments.update_deployment(ctx.donor, %{external_id: nil, status: :pending})

      assert {:error, {:netns_donor_not_running, _id}} =
               SpecBuilder.build(Deployments.get_deployment!(ctx.child.id))
    end
  end

  describe "the spec the DONOR produces" do
    setup ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))
      Map.put(ctx, :child, child)
    end

    test "carries its routed children's Traefik labels", ctx do
      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))

      assert spec.labels["traefik.enable"] == "true"

      assert spec.labels["traefik.http.routers.sonarr-example-com.rule"] ==
               "Host(`sonarr.example.com`)"

      # The child's PORT, resolved against the donor's address.
      assert spec.labels["traefik.http.services.sonarr-example-com.loadbalancer.server.port"] ==
               "8989"
    end

    test "is multi-homed onto ingress so Traefik can actually reach it", ctx do
      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))

      assert Homelab.Infrastructure.internal_network() in spec.bridge_networks
    end

    test "a donor with no ROUTED children stays off ingress", ctx do
      {:ok, _} = Deployments.update_deployment(ctx.child, %{domain: nil})

      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))

      assert spec.bridge_networks == []
      refute Map.has_key?(spec.labels, "traefik.enable")
    end
  end

  # The most common way this arrangement fails, and the one with no error anywhere:
  # gluetun's kill-switch drops traffic to a port it was not told about, so Traefik
  # returns 502 and neither container logs a thing.
  describe "derived gluetun firewall env" do
    test "opens every child's port", ctx do
      {:ok, _child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))

      assert spec.env["FIREWALL_INPUT_PORTS"] == "8989"
    end

    test "an operator's own value always wins", ctx do
      {:ok, _child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, donor} =
        Deployments.update_deployment(ctx.donor, %{
          env_overrides: %{"FIREWALL_INPUT_PORTS" => "9999"}
        })

      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(donor.id))
      assert spec.env["FIREWALL_INPUT_PORTS"] == "9999"
    end

    test "nothing is derived for a donor with no children, or a non-gluetun one", ctx do
      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))
      refute Map.has_key?(spec.env, "FIREWALL_INPUT_PORTS")

      plain = insert(:app_template, slug: "plain-donor", netns_donor_kind: nil)

      plain_donor =
        insert(:deployment,
          tenant: ctx.tenant,
          app_template: plain,
          domain: nil,
          external_id: "plain-1",
          status: :running
        )

      {:ok, _} = Deployments.create_deployment(child_attrs(ctx.tenant, plain_donor))

      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(plain_donor.id))
      refute Map.has_key?(spec.env, "FIREWALL_INPUT_PORTS")
    end
  end

  describe "staleness" do
    setup ctx do
      {:ok, child} =
        Deployments.create_deployment(
          child_attrs(ctx.tenant, ctx.donor, %{
            status: :running,
            external_id: "sonarr-1",
            netns_parent_external_id: "gluetun-container-1"
          })
        )

      Map.put(ctx, :child, child)
    end

    test "a child matching its donor's current container is not stale", ctx do
      refute Netns.stale?(ctx.child, ctx.donor)
      assert Netns.stale_children() == []
    end

    test "re-creating the donor makes every child unstartable", ctx do
      # The child's NetworkMode still names the OLD container. Docker refuses to start
      # it at all, and nothing about the child's own row looks wrong.
      {:ok, donor} =
        Deployments.update_deployment(ctx.donor, %{external_id: "gluetun-container-2"})

      assert Netns.stale?(ctx.child, donor)
      assert [stale] = Netns.stale_children()
      assert stale.id == ctx.child.id
    end

    test "a child that has never been deployed is not stale", ctx do
      {:ok, child} = Deployments.update_deployment(ctx.child, %{netns_parent_external_id: nil})

      refute Netns.stale?(child, ctx.donor)
    end
  end

  # Each of these guards was written, documented, and then reached past by the code that
  # was supposed to feed it — so it silently answered "fine" forever. They are the same
  # class of bug the guards themselves exist to prevent.
  describe "guards that were reaching past their own source of truth" do
    test "declared_ports honours ports_override, not just the template", ctx do
      # Read off the template directly, a port corrected in the Ports tab was invisible:
      # the donor's firewall was opened for the ORIGINAL port and the readiness check,
      # reading the same stale list, agreed the route was fine.
      {:ok, child} =
        Deployments.create_deployment(
          child_attrs(ctx.tenant, ctx.donor, %{
            ports_override: [%{"internal" => 9999, "role" => "web"}]
          })
        )

      assert 9999 in Netns.declared_ports(Deployments.get_deployment!(child.id))
      refute 8989 in Netns.declared_ports(Deployments.get_deployment!(child.id))
    end

    test "the derived firewall rule follows the override too", ctx do
      {:ok, _child} =
        Deployments.create_deployment(
          child_attrs(ctx.tenant, ctx.donor, %{
            ports_override: [%{"internal" => 9999, "role" => "web"}]
          })
        )

      assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.donor.id))
      assert spec.env["FIREWALL_INPUT_PORTS"] == "9999"
    end

    test "host modes are refused even when exposure lives on the TEMPLATE", ctx do
      # Adoption writes exposure to the template and leaves the override nil, so a guard
      # reading only the override was blind for exactly the deployments most likely to be
      # host-mode.
      host_template =
        insert(:app_template,
          slug: "adopted-#{System.unique_integer([:positive])}",
          exposure_mode: :host,
          ports: [%{"internal" => 7777}]
        )

      attrs =
        child_attrs(ctx.tenant, ctx.donor, %{
          app_template_id: host_template.id,
          domain: "adopted.example.com"
        })

      assert {:error, changeset} = Deployments.create_deployment(attrs)
      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "no ports of its own"
    end

    test "a host-networked donor is refused even when that lives on its template", ctx do
      host_template = insert(:app_template, slug: "hass-tpl", exposure_mode: :host_network)

      host_donor =
        insert(:deployment,
          tenant: ctx.tenant,
          app_template: host_template,
          domain: nil,
          exposure_mode_override: nil
        )

      assert {:error, changeset} =
               Deployments.create_deployment(child_attrs(ctx.tenant, host_donor))

      assert %{network_parent_id: [message]} = errors_on(changeset)
      assert message =~ "host networking"
    end
  end

  describe "teardown protection" do
    setup ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))
      Map.put(ctx, :child, child)
    end

    test "a donor with children cannot be deleted", ctx do
      # Detaching them silently would put a VPN'd app back on the tenant network, which
      # is the one outcome the whole arrangement exists to prevent.
      assert {:error, {:netns_donor_in_use, ids}} = Deployments.delete_deployment(ctx.donor)
      assert ctx.child.id in ids
      assert Repo.get(Homelab.Deployments.Deployment, ctx.donor.id)
    end

    test "destroy is refused for the same reason", ctx do
      assert {:error, {:netns_donor_in_use, _ids}} = Deployments.destroy_deployment(ctx.donor)
    end

    test "removing the last child releases the donor", ctx do
      assert {:ok, _} = Deployments.delete_deployment(ctx.child)
      assert {:ok, _} = Deployments.delete_deployment(ctx.donor)
    end
  end

  describe "release ordering" do
    test "a child's release deploys its donor first", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} = Deployments.deploy_release(Deployments.get_deployment!(child.id))
      release = Repo.preload(release, :steps)

      steps = Enum.sort_by(release.steps, & &1.position)
      types = Enum.map(steps, & &1.type)

      # The donor is the first CONTAINER. `:ensure_ingress_proxy` may precede it for a
      # routed release — it creates nothing, and the ordering claim here is about which
      # workload is built first.
      assert Enum.find_index(types, &(&1 in [:dependency_container, :app_container])) ==
               Enum.find_index(types, &(&1 == :dependency_container))

      assert Enum.find(steps, &(&1.type == :dependency_container)).resource_handle == %{
               "deployment_id" => ctx.donor.id
             }

      # ...and only then the child itself.
      assert Enum.find_index(types, &(&1 == :app_container)) >
               Enum.find_index(types, &(&1 == :dependency_container))
    end

    # The compose shape `netns_donor_companions/1`'s own comment names: a bundle where
    # gluetun is BOTH the namespace donor and an explicit companion. The comment claimed
    # the set was de-duplicated "because planning it twice would deploy it twice"; no
    # dedup existed anywhere on the path, so the donor got two `:dependency_container`
    # steps. Both write `external_id`, so only the second is compensatable and the first
    # container is orphaned.
    #
    # Fixed at the root rather than at a call site, so the invariant the comment asserts
    # is actually enforced for every caller — `deploy_wizard_live.ex` reaches this
    # directly with an explicit companion list.
    test "a donor that is also an explicit companion is planned once", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} =
        Deployments.deploy_release(Deployments.get_deployment!(child.id), [
          Deployments.get_deployment!(ctx.donor.id)
        ])

      release = Repo.preload(release, :steps)
      donor_handle = %{"deployment_id" => ctx.donor.id}

      assert Enum.count(
               release.steps,
               &(&1.type == :dependency_container and &1.resource_handle == donor_handle)
             ) == 1

      assert Enum.count(
               release.steps,
               &(&1.type == :await_health and &1.resource_handle == donor_handle)
             ) == 1
    end

    test "a stack redeploy re-creates the donor and then every child", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(child.id))
      release = Repo.preload(release, :steps)

      steps = Enum.sort_by(release.steps, & &1.position)
      types = Enum.map(steps, & &1.type)

      # The release is driven from the DONOR — it is what gets a new container id, and
      # it is the first CONTAINER in the plan. `:ensure_ingress_proxy` precedes it (the
      # child is routed, so the donor is), and creates nothing.
      assert release.deployment_id == ctx.donor.id

      assert Enum.find_index(types, &(&1 in [:app_container, :netns_child_container])) ==
               Enum.find_index(types, &(&1 == :app_container))

      child_step = Enum.find(steps, &(&1.type == :netns_child_container))
      assert child_step.resource_handle == %{"deployment_id" => child.id}
      assert child_step.position > Enum.find(steps, &(&1.type == :app_container)).position
    end

    # The donor's Traefik labels serve the CHILDREN's routes — that is the whole reason
    # a child's route change re-creates the donor. Publishing before the children were
    # (re)created advertised every one of those routes to a namespace holding nothing
    # yet, so the window between "donor healthy" and "last child healthy" served 502s on
    # names that had been working a moment earlier.
    test "a routed stack publishes ingress only after every child exists", ctx do
      {:ok, donor} = Deployments.update_deployment(ctx.donor, %{domain: "vpn.example.com"})
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(child.id))
      release = Repo.preload(release, :steps)

      steps = Enum.sort_by(release.steps, & &1.position)
      types = Enum.map(steps, & &1.type)

      last_child = Enum.find_index(Enum.reverse(types), &(&1 == :netns_child_container))
      last_child = length(types) - 1 - last_child

      for advertising <- [:sync_domain, :publish_dns] do
        index = Enum.find_index(types, &(&1 == advertising))

        # `Enum.find_index/2` returns nil for a step that was never planned, and in
        # Elixir's term order an atom sorts ABOVE every integer — so `nil > last_child`
        # is `true` and the ordering assertion below silently asserts nothing. The
        # third element of this list used to be `:publish_ingress`, which this donor
        # (exposure `:service`) never gets, so that iteration measured nothing at all.
        assert is_integer(index), "#{advertising} must be planned"

        assert index > last_child, "#{advertising} must come after the last child"
      end

      # And `:publish_ingress` is correctly absent rather than merely unordered: the
      # donor is `:service`-exposed, so `ingress_published?/1` is false and the step
      # would fall through having done nothing.
      refute :publish_ingress in types

      # The proxy is the exception, and is still first: it creates nothing and
      # advertises nothing — it is a precondition of the route.
      assert Enum.at(types, 0) == :ensure_ingress_proxy
    end

    # The shape this actually affects, and the one the test above sidesteps by giving
    # the donor a domain first: a gluetun donor has NO domain of its own, and every
    # name in the stack belongs to a child. `SpecBuilder` already treats that donor as
    # routed — it emits `traefik.enable=true` and multi-homes it onto the ingress
    # network precisely because the children's routes resolve to the donor's address.
    # A predicate that reads only `donor.domain` therefore plans no proxy and no
    # ingress for the one topology that needs both.
    test "a donor with no domain of its own is routed by its children", ctx do
      {:ok, _child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(ctx.donor.id))
      release = Repo.preload(release, :steps)
      types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

      assert Deployments.get_deployment!(ctx.donor.id).domain in [nil, ""]
      assert :ensure_ingress_proxy in types

      # But NOT `publish_ingress`. `publish_deployment/1` gates on `ingress_published?/1`,
      # which requires the deployment's OWN domain — so for a domainless donor the step
      # falls through to `:ok` having done nothing, while recording `"published" => true`.
      # A step that cannot act should not be planned; the donor's ingress membership
      # comes from `SpecBuilder`'s `bridge_networks` at container-create time, which is
      # the mechanism that actually works.
      refute :publish_ingress in types
    end

    # A donor whose children are NOT proxy-routed gains nothing from ingress —
    # `SpecBuilder` does not multi-home it either. The widened predicate has to match
    # that rule, or `publish_ingress` attaches a container Traefik has no labels for.
    test "a donor whose children are internal-only is not routed", ctx do
      attrs = child_attrs(ctx.tenant, ctx.donor, %{exposure_mode_override: "service"})
      {:ok, _child} = Deployments.create_deployment(attrs)

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(ctx.donor.id))
      release = Repo.preload(release, :steps)
      types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

      refute :ensure_ingress_proxy in types
      refute :publish_ingress in types
    end

    # A stack redeploy is most often TRIGGERED by a child's route changing — that is
    # the whole reason a child's route change re-creates the donor. So the one operation
    # most likely to be moving a child's name was also the one that never synced that
    # child's Domain row or published its A record: the routing steps carried an empty
    # handle, so they all targeted the donor. Deployed standalone through
    # `deploy_release/2` the same child gets both.
    test "each routed child gets its own domain and dns steps", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(ctx.donor.id))
      release = Repo.preload(release, :steps)
      steps = Enum.sort_by(release.steps, & &1.position)

      handle = %{"deployment_id" => child.id}

      assert Enum.any?(steps, &(&1.type == :sync_domain and &1.resource_handle == handle))
      assert Enum.any?(steps, &(&1.type == :publish_dns and &1.resource_handle == handle))

      # After that child's container exists and is healthy — a name must not be
      # published ahead of the thing answering to it.
      child_health =
        Enum.find(steps, &(&1.type == :await_health and &1.resource_handle == handle))

      child_sync = Enum.find(steps, &(&1.type == :sync_domain and &1.resource_handle == handle))
      assert child_sync.position > child_health.position

      # And NO `publish_ingress` anywhere in this stack. A child has no network endpoint
      # to attach, so it never gets one — but neither does this donor, because it holds
      # no domain of its own: `publish_deployment/1` gates on `ingress_published?/1`
      # (`deployments.ex:184`), which requires the deployment's OWN domain, so the step
      # would fall through to `:ok` having done nothing while recording
      # `"published" => true`.
      #
      # The donor is still reachable — `SpecBuilder` puts it on the ingress network via
      # `bridge_networks` at container-create time, because its children's routes resolve
      # to its address. This step never contributed to that. A donor that DOES hold a
      # domain gets exactly one, asserted below.
      assert Enum.count(steps, &(&1.type == :publish_ingress)) == 0
    end

    # The Sonarr-behind-gluetun shape deployed on its own. The child holds a real domain,
    # so every name-shaped predicate says publish it — but `publish_deployment/1` gates on
    # `attachable?/1`, and a container living in another's namespace has no endpoint to
    # attach. The step would fall through to `:ok` and record `"published" => true` for
    # work that did not happen. Its route is real and is served by the DONOR, which
    # `SpecBuilder` multi-homes onto ingress via `bridge_networks` at create time.
    test "a netns child with its own domain is planned no publish_ingress", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))
      {:ok, child} = Deployments.update_deployment(child, %{domain: "sonarr.example.com"})

      {:ok, release} = Deployments.deploy_release(Deployments.get_deployment!(child.id))
      steps = Repo.preload(release, :steps).steps
      types = Enum.map(steps, & &1.type)

      refute :publish_ingress in types

      # The name is still claimed — those steps belong to whoever holds the domain, and
      # this child does. Only the attach is skipped.
      assert :sync_domain in types
      assert :publish_dns in types
    end

    # Giving the donor a domain does NOT make the attach meaningful: a gluetun donor is
    # `exposure_mode: :service`, so `ingress_published?/1` is false via
    # `Access.proxy_mode?/1` and `publish_deployment/1` would no-op. A stray domain on a
    # non-proxy deployment is the third shape `reachability_steps/1` has to exclude.
    #
    # An earlier revision of this test asserted exactly one `publish_ingress` here, which
    # was pinning that no-op. The positive case — a domained PROXY deployment gets one —
    # is covered by the full step-list assertion in `greenfield_release_test.exs`.
    test "a :service donor carrying a stray domain is still planned no publish_ingress", ctx do
      {:ok, donor} = Deployments.update_deployment(ctx.donor, %{domain: "vpn.example.com"})
      {:ok, _child} = Deployments.create_deployment(child_attrs(ctx.tenant, donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(donor.id))
      steps = Repo.preload(release, :steps).steps

      assert Deployments.get_deployment!(donor.id).domain == "vpn.example.com"
      assert Enum.count(steps, &(&1.type == :publish_ingress)) == 0
    end

    test "driving the stack from the DONOR gives the same release", ctx do
      {:ok, child} = Deployments.create_deployment(child_attrs(ctx.tenant, ctx.donor))

      {:ok, release} = Deployments.redeploy_netns_stack(Deployments.get_deployment!(ctx.donor.id))
      release = Repo.preload(release, :steps)

      assert release.deployment_id == ctx.donor.id

      assert Enum.any?(
               release.steps,
               &(&1.type == :netns_child_container and
                   &1.resource_handle == %{"deployment_id" => child.id})
             )
    end
  end
end
