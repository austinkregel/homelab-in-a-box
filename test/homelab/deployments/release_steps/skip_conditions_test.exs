defmodule Homelab.Deployments.ReleaseSteps.SkipConditionsTest do
  @moduledoc """
  Each handler's `skip?/2`: the verdict, and the exact message an operator reads when a
  step declines.
  """
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.ReleaseFacts
  alias Homelab.Deployments.ReleaseStep

  alias Homelab.Deployments.ReleaseSteps.{
    AwaitHealth,
    DeployContainer,
    EnsureDatastoreGrants,
    EnsureIngressProxy,
    ProvisionCredentials,
    PublishDns,
    PublishIngress,
    SyncDomain,
    VerifyPublicUrl
  }

  defp facts_for(deployment),
    do: ReleaseFacts.build(Deployments.get_deployment!(deployment.id))

  defp ctx(deployment), do: %{facts: facts_for(deployment)}
  defp step(handle \\ %{}), do: %ReleaseStep{resource_handle: handle}

  defp routed(attrs \\ []) do
    template = insert(:app_template, exposure_mode: :public)

    insert(
      :deployment,
      Keyword.merge([app_template: template, domain: "app.example.test"], attrs)
    )
  end

  defp domainless(attrs \\ []) do
    template = insert(:app_template, exposure_mode: :public)
    insert(:deployment, Keyword.merge([app_template: template, domain: nil], attrs))
  end

  # A gluetun-shaped donor with one routed child in its namespace.
  defp donor_with_routed_child do
    tenant = insert(:tenant)

    donor =
      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, exposure_mode: :service),
        domain: nil,
        external_id: "donor-1"
      )

    child =
      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, exposure_mode: :public),
        domain: "child.example.test",
        network_parent_id: donor.id
      )

    {donor, child}
  end

  describe "EnsureIngressProxy.skip?/2" do
    test "runs for a deployment holding its own domain" do
      assert :run = EnsureIngressProxy.skip?(step(), ctx(routed()))
    end

    test "runs for a domainless donor carrying a routed child's name" do
      {donor, _child} = donor_with_routed_child()

      facts = facts_for(donor)
      refute facts.own_domain?
      assert facts.carries_child_routes?

      assert :run = EnsureIngressProxy.skip?(step(), %{facts: facts})
    end

    test "skips when neither holds, naming both conditions" do
      assert {:skip, reason} = EnsureIngressProxy.skip?(step(), ctx(domainless()))
      assert reason =~ "it holds no domain"
      assert reason =~ "no routed child publishes through it"
    end
  end

  describe "SyncDomain.skip?/2" do
    test "runs for a deployment holding its own domain" do
      assert :run = SyncDomain.skip?(step(), ctx(routed()))
    end

    test "skips a deployment with no name to claim" do
      assert {:skip, "it holds no domain to claim"} =
               SyncDomain.skip?(step(), ctx(domainless()))
    end
  end

  describe "PublishDns.skip?/2" do
    test "runs for a deployment holding its own domain" do
      assert :run = PublishDns.skip?(step(), ctx(routed()))
    end

    test "skips a deployment with no name to resolve" do
      assert {:skip, "it holds no domain to resolve"} =
               PublishDns.skip?(step(), ctx(domainless()))
    end
  end

  describe "VerifyPublicUrl.skip?/2" do
    test "runs for a deployment holding its own domain" do
      assert :run = VerifyPublicUrl.skip?(step(), ctx(routed()))
    end

    test "skips a deployment with no URL to answer at" do
      assert {:skip, "it holds no domain to answer at"} =
               VerifyPublicUrl.skip?(step(), ctx(domainless()))
    end
  end

  describe "PublishIngress.skip?/2" do
    test "runs for a proxy-routed deployment with an endpoint of its own" do
      assert :run = PublishIngress.skip?(step(), ctx(routed()))
    end

    test "skips a deployment that is not proxy-routed" do
      internal = insert(:deployment, app_template: insert(:app_template, exposure_mode: :service))

      assert {:skip, "it is not proxy-routed with a domain of its own"} =
               PublishIngress.skip?(step(), ctx(internal))
    end

    # The Sonarr-behind-gluetun shape: proxy-routed and named, but the daemon refuses
    # `/networks/<n>/connect` on a container sharing another's namespace.
    test "skips a netns child, which has no endpoint to attach" do
      {_donor, child} = donor_with_routed_child()

      assert {:skip, reason} = PublishIngress.skip?(step(), ctx(child))
      assert reason =~ "shares another namespace"
    end

    # A container in the host namespace holds no endpoint on any user-defined network,
    # and is not proxy-routed either — the first condition is what reports.
    test "skips a host-networked deployment carrying a domain" do
      host =
        insert(:deployment,
          app_template: insert(:app_template, exposure_mode: :host_network),
          domain: "host.example.test",
          exposure_mode_override: "host_network"
        )

      facts = facts_for(host)
      assert facts.host_network?
      refute facts.attachable?
      refute facts.ingress_published?

      assert {:skip, "it is not proxy-routed with a domain of its own"} =
               PublishIngress.skip?(step(), %{facts: facts})
    end
  end

  describe "EnsureDatastoreGrants.skip?/2" do
    test "runs for a companion whose image is an engine Grants can drive" do
      datastore = insert(:deployment, app_template: insert(:app_template, image: "mariadb:11"))

      assert :run = EnsureDatastoreGrants.skip?(step(), ctx(datastore))
    end

    test "skips a companion that is not a datastore" do
      companion = insert(:deployment, app_template: insert(:app_template, image: "nginx:1.27"))

      assert {:skip, "this companion is not a datastore homelab can grant on"} =
               EnsureDatastoreGrants.skip?(step(), ctx(companion))
    end
  end

  # The one handler that reads the step rather than the facts.
  describe "ProvisionCredentials.skip?/2" do
    test "runs when the step carries specs to generate" do
      handle = %{"specs" => [%{"key" => "DB_PASSWORD", "kind" => "password"}]}

      assert :run = ProvisionCredentials.skip?(step(handle), %{})
    end

    test "skips when the step carries no specs" do
      assert {:skip, "no credentials to generate for this deployment"} =
               ProvisionCredentials.skip?(step(%{}), %{})
    end

    test "skips rather than raising when the handle is empty or nil" do
      assert {:skip, _} = ProvisionCredentials.skip?(%ReleaseStep{resource_handle: nil}, %{})
      assert {:skip, _} = ProvisionCredentials.skip?(step(%{"specs" => []}), %{})
    end
  end

  # `@optional_callbacks skip?: 2` — a handler that performs work unconditionally
  # implements none, and the runner must read that as "run".
  describe "handlers with no skip?/2" do
    test "the container and health handlers export none" do
      for module <- [DeployContainer, AwaitHealth] do
        Code.ensure_loaded!(module)
        assert function_exported?(module, :run, 2)
        refute function_exported?(module, :skip?, 2)
      end
    end
  end
end
