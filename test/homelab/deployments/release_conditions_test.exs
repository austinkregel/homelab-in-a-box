defmodule Homelab.Deployments.ReleaseConditionsTest do
  @moduledoc """
  Named facts about a deployment, and the conditions a step's `skip?/2` writes in terms
  of them.
  """
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.ReleaseFacts
  alias Homelab.Deployments.ReleaseSteps.Conditions

  describe "Conditions.all/2" do
    test "runs when every condition holds" do
      facts = %ReleaseFacts{own_domain?: true, attachable?: true}

      assert :run =
               Conditions.all(facts, [
                 {:own_domain?, "no domain"},
                 {:attachable?, "no endpoint"}
               ])
    end

    test "reports the first failing condition's own message" do
      facts = %ReleaseFacts{own_domain?: true, attachable?: false, ingress_published?: false}

      assert {:skip, "no endpoint"} =
               Conditions.all(facts, [
                 {:own_domain?, "no domain"},
                 {:attachable?, "no endpoint"},
                 {:ingress_published?, "not proxy-routed"}
               ])
    end

    test "a fact no struct answers to raises rather than reading as false" do
      assert_raise KeyError, fn ->
        Conditions.all(%ReleaseFacts{}, [{:not_a_fact?, "typo"}])
      end
    end
  end

  describe "Conditions.any/2" do
    test "runs when at least one condition holds" do
      facts = %ReleaseFacts{own_domain?: false, carries_child_routes?: true}

      assert :run =
               Conditions.any(facts, [
                 {:own_domain?, "it holds no domain"},
                 {:carries_child_routes?, "no routed child publishes through it"}
               ])
    end

    test "names every condition when none of them hold" do
      assert {:skip, reason} =
               Conditions.any(%ReleaseFacts{}, [
                 {:own_domain?, "it holds no domain"},
                 {:carries_child_routes?, "no routed child publishes through it"}
               ])

      assert reason =~ "it holds no domain"
      assert reason =~ "no routed child publishes through it"
    end
  end

  describe "facts" do
    test "a proxy-routed deployment with a domain is routed, published and attachable" do
      template = insert(:app_template, exposure_mode: :public)
      deployment = insert(:deployment, app_template: template, domain: "app.example.test")

      facts = ReleaseFacts.build(deployment)

      assert facts.own_domain?
      assert facts.routed?
      assert facts.proxy_mode?
      assert facts.ingress_published?
      assert facts.attachable?
      refute facts.netns_child?
      refute facts.netns_donor?
    end

    test "a netns child holds a name it cannot attach for" do
      tenant = insert(:tenant)
      donor_template = insert(:app_template, exposure_mode: :service, netns_donor_kind: "gluetun")

      donor =
        insert(:deployment,
          tenant: tenant,
          app_template: donor_template,
          domain: nil,
          external_id: "donor-1"
        )

      child_template = insert(:app_template, exposure_mode: :public)

      child =
        insert(:deployment,
          tenant: tenant,
          app_template: child_template,
          domain: "sonarr.example.test",
          network_parent_id: donor.id
        )

      child_facts = ReleaseFacts.build(child)

      assert child_facts.own_domain?
      assert child_facts.ingress_published?
      assert child_facts.netns_child?
      refute child_facts.attachable?

      donor_facts = ReleaseFacts.build(Deployments.get_deployment!(donor.id))

      assert donor_facts.netns_donor?
      assert donor_facts.netns_donor_kind?
      assert donor_facts.carries_child_routes?
      assert donor_facts.routed?
      refute donor_facts.own_domain?
      refute donor_facts.ingress_published?
    end

    test "a datastore companion is named as one" do
      template = insert(:app_template, image: "mariadb:11")
      companion = insert(:deployment, app_template: template, domain: nil)

      assert ReleaseFacts.build(companion).datastore?
      refute ReleaseFacts.build(insert(:deployment)).datastore?
    end

    test "a host-networked deployment is named as one and is not attachable" do
      template = insert(:app_template, exposure_mode: :host_network)

      host =
        insert(:deployment,
          app_template: template,
          domain: "host.example.test",
          exposure_mode_override: "host_network"
        )

      facts = ReleaseFacts.build(host)

      assert facts.host_network?
      refute facts.attachable?
      refute facts.proxy_mode?
      refute facts.ingress_published?
    end

    test "a declared healthcheck is named, and a template without one is not" do
      with_check = insert(:app_template, health_check: %{"path" => "/health"})
      without = insert(:app_template, health_check: %{})

      assert ReleaseFacts.build(insert(:deployment, app_template: with_check)).declares_healthcheck?
      refute ReleaseFacts.build(insert(:deployment, app_template: without)).declares_healthcheck?
    end

    test "no deployment means no facts, rather than a raise" do
      facts = ReleaseFacts.build(nil)

      refute facts.own_domain?
      refute facts.attachable?
    end
  end

  describe "for_step/2" do
    setup do
      tenant = insert(:tenant)

      app =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, exposure_mode: :public),
          domain: "app.example.test"
        )

      companion =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, image: "mariadb:11"),
          domain: nil
        )

      %{ctx: %{release: nil, deployment: app}, app: app, companion: companion}
    end

    test "a step naming a companion gets THAT deployment's facts", ctx do
      step = %{resource_handle: %{"deployment_id" => ctx.companion.id}}

      facts = ReleaseFacts.for_step(step, ctx.ctx)

      assert facts.datastore?
      refute facts.own_domain?
    end

    test "a step with no handle falls back to the release's own deployment", ctx do
      facts = ReleaseFacts.for_step(%{resource_handle: %{}}, ctx.ctx)

      assert facts.own_domain?
      assert facts.ingress_published?
      refute facts.datastore?
    end

    test "a handle naming a deployment that is gone yields empty facts", ctx do
      {:ok, _} = Deployments.delete_deployment(ctx.companion)

      step = %{resource_handle: %{"deployment_id" => ctx.companion.id}}

      assert ReleaseFacts.for_step(step, ctx.ctx) == %ReleaseFacts{}
    end

    test "a nil handle is read as no handle", ctx do
      facts = ReleaseFacts.for_step(%{resource_handle: nil}, ctx.ctx)

      assert facts.own_domain?
    end
  end
end
