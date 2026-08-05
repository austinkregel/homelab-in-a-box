defmodule Homelab.Deployments.ReleaseSteps.RoutingStepsTest do
  @moduledoc """
  The three steps that carry `do_deploy/1`'s routing side effects into the saga:
  `EnsureIngressProxy`, `SyncDomain` and `PublishDns`. Before these existed a release
  reached `:running` for a routed app with no proxy ensured, no Domain row and no A
  record — and said nothing about it.

  Handler-level here; `greenfield_release_test.exs` covers the same ground end to end
  through `ReleaseRunner`.
  """
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.ReleaseStep
  alias Homelab.Deployments.ReleaseSteps.{EnsureIngressProxy, PublishDns, SyncDomain}
  alias Homelab.Networking

  setup :set_mox_global
  setup :verify_on_exit!

  defp routed_deployment(fqdn) do
    template = insert(:app_template, required_env: [], default_env: %{}, volumes: [], ports: [])
    insert(:deployment, app_template: template, domain: fqdn, external_id: nil)
  end

  defp ctx(deployment), do: %{release: nil, deployment: deployment}
  defp step(handle), do: %ReleaseStep{resource_handle: handle}

  defp stub_dns_provider do
    stub(Homelab.Mocks.DnsProvider, :list_records, fn _zone -> {:ok, []} end)
    stub(Homelab.Mocks.DnsProvider, :create_record, fn _zone, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :update_record, fn _zone, _id, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :delete_record, fn _zone, _id -> :ok end)
  end

  describe "EnsureIngressProxy" do
    # Best-effort ON PURPOSE, matching `ensure_traefik_if_needed/1`. `ensure_traefik/0`
    # returns `{:error, :dns_token_missing}` on any install without a DNS-01 token —
    # which is the normal state for a LAN-only homelab and for anyone running Traefik
    # from their own compose file. Failing the release there would make every routed
    # deploy impossible on those installs.
    #
    # It is not swallowed, though: the handle says so, which is the part `do_deploy/1`
    # had nowhere to put.
    test "records an unavailable proxy in the handle instead of failing the release" do
      app = routed_deployment("proxy.example.test")

      assert {:ok, handle} = EnsureIngressProxy.run(step(%{}), ctx(app))
      assert handle["ingress_proxy"] == "unavailable"
      assert handle["error"] =~ "dns_token_missing"
    end

    # Traefik is a shared singleton: every routed deployment on the host resolves
    # through the same container. Compensating this step would sever every OTHER
    # deployment's route because one release rolled back.
    test "has no compensate/2 — deliberately" do
      refute function_exported?(EnsureIngressProxy, :compensate, 2)
    end
  end

  describe "SyncDomain" do
    test "creates the Domain row and marks the handle as the creator" do
      app = routed_deployment("fresh.example.test")

      assert {:ok, handle} = SyncDomain.run(step(%{}), ctx(app))
      assert handle["fqdn"] == "fresh.example.test"
      assert handle["created"] == true
      assert handle["reclaimed"] == false

      assert {:ok, row} = Networking.get_domain_by_fqdn("fresh.example.test")
      assert row.deployment_id == app.id
    end

    # `sync_domain_records/1` is convergent, so re-running after a crash must not
    # produce a second row or flip the handle's provenance from reclaimed back to
    # created — which is what `compensate/2` keys off.
    test "is idempotent, and a second run reports a reclaim rather than a create" do
      app = routed_deployment("twice.example.test")

      assert {:ok, first} = SyncDomain.run(step(%{}), ctx(app))
      assert {:ok, second} = SyncDomain.run(step(%{}), ctx(app))

      assert first["created"] == true
      assert second["created"] == false
      assert second["reclaimed"] == true
      assert second["domain_id"] == first["domain_id"]
    end

    test "compensate deletes a row it created" do
      app = routed_deployment("undo.example.test")
      {:ok, handle} = SyncDomain.run(step(%{}), ctx(app))

      assert :ok = SyncDomain.compensate(step(handle), ctx(app))
      assert {:error, :not_found} = Networking.get_domain_by_fqdn("undo.example.test")

      # Idempotent: the row is already gone.
      assert :ok = SyncDomain.compensate(step(handle), ctx(app))
    end

    # A reclaimed row predates this release. Deleting it would destroy TLS state, the
    # zone link, and whatever claim its previous owner had — none of which this release
    # created.
    test "compensate leaves a row it only reclaimed" do
      other = routed_deployment("shared.example.test")

      {:ok, _} =
        Networking.create_domain(%{fqdn: "shared.example.test", deployment_id: other.id})

      app = routed_deployment("shared.example.test")
      {:ok, handle} = SyncDomain.run(step(%{}), ctx(app))
      assert handle["reclaimed"] == true

      assert :ok = SyncDomain.compensate(step(handle), ctx(app))
      assert {:ok, _} = Networking.get_domain_by_fqdn("shared.example.test")
    end

    # `sync_domain_records/1` returns `:ok` whether or not the row was written — it
    # logs the failure and moves on, which is right for a fire-and-forget hook and
    # wrong for a saga step. The read-back is what turns a dropped row into a failure.
    test "fails when the fqdn is not one the Domain schema will accept" do
      app = routed_deployment("has_underscore.example.test")

      assert {:error, {:sync_domain_failed, _id, :domain_row_not_persisted}} =
               SyncDomain.run(step(%{}), ctx(app))
    end
  end

  describe "PublishDns" do
    test "writes managed A records and reports the count" do
      stub_dns_provider()
      app = routed_deployment("dns.example.test")

      assert {:ok, handle} = PublishDns.run(step(%{}), ctx(app))
      assert handle["fqdn"] == "dns.example.test"
      assert handle["record_count"] > 0

      records = Networking.list_dns_records_for_deployment(app.id)
      assert Enum.all?(records, & &1.managed)
    end

    test "is idempotent — a re-run upserts rather than duplicating" do
      stub_dns_provider()
      app = routed_deployment("again.example.test")

      {:ok, _} = PublishDns.run(step(%{}), ctx(app))
      before = length(Networking.list_dns_records_for_deployment(app.id))

      {:ok, _} = PublishDns.run(step(%{}), ctx(app))
      assert length(Networking.list_dns_records_for_deployment(app.id)) == before
    end

    # An A record is the one artifact in the plan that is externally visible and cached
    # by resolvers. Left behind after a rollback it points the world at a container
    # that no longer exists, for as long as the TTL says.
    test "compensate removes the managed records, at the provider as well as locally" do
      test_pid = self()
      stub_dns_provider()

      stub(Homelab.Mocks.DnsProvider, :delete_record, fn _zone, id ->
        send(test_pid, {:provider_deleted, id})
        :ok
      end)

      app = routed_deployment("gone.example.test")
      {:ok, handle} = PublishDns.run(step(%{}), ctx(app))

      assert :ok = PublishDns.compensate(step(handle), ctx(app))
      assert Networking.list_dns_records_for_deployment(app.id) == []
      assert_received {:provider_deleted, _}

      # Idempotent: nothing left to delete.
      assert :ok = PublishDns.compensate(step(handle), ctx(app))
    end

    # An operator's hand-made record for the same deployment is not ours to delete.
    test "compensate leaves unmanaged records alone" do
      stub_dns_provider()
      app = routed_deployment("mixed.example.test")
      {:ok, _} = PublishDns.run(step(%{}), ctx(app))

      [managed | _] = Networking.list_dns_records_for_deployment(app.id)

      {:ok, _} =
        Networking.create_dns_record(%{
          name: "hand",
          type: "A",
          value: "10.0.0.9",
          scope: :internal,
          managed: false,
          deployment_id: app.id,
          dns_zone_id: managed.dns_zone_id
        })

      assert :ok = PublishDns.compensate(step(%{"deployment_id" => app.id}), ctx(app))

      assert [survivor] = Networking.list_dns_records_for_deployment(app.id)
      assert survivor.managed == false
    end
  end

  describe "the imperative path is unchanged" do
    # The whole tier is additive: `deploy_now/1` keeps its own copies of these hooks
    # and keeps working. `detect_ip_config/0` is the one thing they now SHARE, so the
    # saga and the imperative path cannot publish two different addresses for the same
    # deployment.
    test "detect_ip_config/0 is the single source both paths read" do
      config = Deployments.detect_ip_config()
      assert Map.has_key?(config, :internal_ip)
      assert config.internal_ip == config.public_ip
    end
  end
end
