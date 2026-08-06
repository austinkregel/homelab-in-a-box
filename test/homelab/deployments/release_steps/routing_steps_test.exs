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

  # A PERSISTED step, as the runner actually hands one to a handler. Load-bearing for
  # the reclaim tests: a bare struct has no id, so nothing a handler writes to its own
  # row can be read back.
  defp persisted_step(deployment, type) do
    {:ok, release} =
      Homelab.Deployments.Releases.plan_release(deployment, [%{type: type, resource_handle: %{}}])

    [step] = release.steps
    {release, step}
  end

  # What `ReleaseRunner.reclaim_running_steps/1` leaves behind after a crashed node:
  # the step goes back to `:pending` and is re-read from the database.
  defp reread(step), do: Repo.get!(ReleaseStep, step.id)

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
    #
    # Asserted against a module confirmed to be LOADED and to export `run/2`, so this
    # cannot quietly pass by the module having been renamed out from under it.
    test "has no compensate/2 — deliberately" do
      Code.ensure_loaded!(EnsureIngressProxy)
      assert function_exported?(EnsureIngressProxy, :run, 2)
      refute function_exported?(EnsureIngressProxy, :compensate, 2)
    end

    # `Infrastructure.ensure_traefik/0` is a `with` with no `else`, so it returns
    # whatever any clause returned — including `Docker.Network.ensure/1`'s own shapes.
    # A `case` matching only the three expected returns raises `CaseClauseError`, the
    # runner's rescue turns that into a failed step, and a full rollback follows: the
    # exact inversion of this module's stated contract that a proxy problem never fails
    # a release.
    test "an unexpected return from ensure_traefik is still not fatal" do
      app = routed_deployment("weird.example.test")

      Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:error, :enoent, :extra} end)
      on_exit(fn -> Application.delete_env(:homelab, :ingress_proxy_ensurer) end)

      assert {:ok, handle} = EnsureIngressProxy.run(step(%{}), ctx(app))
      assert handle["ingress_proxy"] == "unavailable"
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

    # `sync_domain_records/1` is convergent, so re-running must not produce a second
    # row. A SEPARATE, later invocation against a row that already exists is a genuine
    # reclaim — this is the case where `created: false` is the right answer.
    test "is idempotent, and a fresh invocation over an existing row is a reclaim" do
      app = routed_deployment("twice.example.test")

      assert {:ok, first} = SyncDomain.run(step(%{}), ctx(app))
      assert {:ok, second} = SyncDomain.run(step(%{}), ctx(app))

      assert first["created"] == true
      assert second["created"] == false
      assert second["reclaimed"] == true
      assert second["domain_id"] == first["domain_id"]
    end

    # THE reclaim bug. `ReleaseRunner` persists a handle only at the completion CAS, so
    # a node that dies after the handler wrote the Domain row but before that CAS loses
    # the provenance entirely — `reclaim_running_steps/1` returns the step to `:pending`
    # with an EMPTY `resource_handle`, and the re-run reads a row that now exists and
    # concludes it was reclaimed. `compensate/2` then refuses to delete a row this
    # release did create, stranding the unique `fqdn` claim this step exists to protect.
    #
    # Note the provenance has to be durable BEFORE the mutation, not merely carried in
    # the returned handle: the returned handle is exactly what the crash discards.
    test "provenance survives a step reclaimed after the row was written" do
      app = routed_deployment("crashed.example.test")
      {_release, step} = persisted_step(app, :sync_domain)

      # First attempt: writes the row, then the node dies before the runner can record
      # the returned handle.
      assert {:ok, _discarded} = SyncDomain.run(step, ctx(app))
      assert {:ok, _} = Networking.get_domain_by_fqdn("crashed.example.test")

      # Resume: the step is re-read and re-run from scratch.
      assert {:ok, handle} = SyncDomain.run(reread(step), ctx(app))
      assert handle["created"] == true

      # ...so compensation still undoes what this release actually did.
      assert :ok = SyncDomain.compensate(step(handle), ctx(app))
      assert {:error, :not_found} = Networking.get_domain_by_fqdn("crashed.example.test")
    end

    # The same durability must not manufacture provenance. A row that predates the step
    # is still a reclaim after a reclaim.
    test "a reclaimed row stays reclaimed across a re-run" do
      other = routed_deployment("pre.example.test")
      {:ok, _} = Networking.create_domain(%{fqdn: "pre.example.test", deployment_id: other.id})

      app = routed_deployment("pre.example.test")
      {_release, step} = persisted_step(app, :sync_domain)

      assert {:ok, _} = SyncDomain.run(step, ctx(app))
      assert {:ok, handle} = SyncDomain.run(reread(step), ctx(app))

      assert handle["created"] == false
      assert handle["reclaimed"] == true

      assert :ok = SyncDomain.compensate(step(handle), ctx(app))
      assert {:ok, _} = Networking.get_domain_by_fqdn("pre.example.test")
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

    # `sync_domain_records/1`'s FIRST act is `retire_stale_domains/2`, which DELETES the
    # deployment's rows for every other name — TLS status, zone link, exposure and all.
    # That is a destruction this step performs, and the moduledoc claimed `"created" =>
    # true` meant deleting the created row "restores exactly the prior world". It does
    # not: `["first"]` became `["second"]` and then `[]`.
    #
    # The retirement is deliberately NOT restored — see the moduledoc — but it must be
    # RECORDED, so a rollback leaves a legible account of what it could not undo. It was
    # in neither branch of the handle.
    test "records the rows it retires, and does not resurrect them on compensate" do
      # A deployment whose name has moved on but whose `Domain` row has not: the state
      # this step exists to converge, and the one where its retirement destroys the
      # most. (Built directly rather than through `update_deployment/2`, which runs
      # `sync_domain_records/1` itself and would have already retired the row.)
      app = routed_deployment("second.example.test")

      {:ok, _} =
        Networking.create_domain(%{
          fqdn: "first.example.test",
          deployment_id: app.id,
          exposure_mode: :public,
          tls_status: :active
        })

      moved = Deployments.get_deployment!(app.id)

      assert {:ok, handle} = SyncDomain.run(step(%{}), ctx(moved))
      assert [retired] = handle["retired"]
      assert retired["fqdn"] == "first.example.test"
      assert retired["exposure_mode"] == "public"
      assert retired["tls_status"] == "active"

      assert :ok = SyncDomain.compensate(step(handle), ctx(moved))

      # The row this step created is gone; the retired one stays gone, as documented.
      assert {:error, :not_found} = Networking.get_domain_by_fqdn("second.example.test")
      assert {:error, :not_found} = Networking.get_domain_by_fqdn("first.example.test")
    end

    # The same account has to survive a crash. The retirement is observed BEFORE the
    # mutation and the returned handle is what the crash discards, so it is persisted
    # through `record_step_handle/2` alongside the created-vs-reclaimed provenance —
    # the re-run cannot re-derive it, because the first attempt already deleted the rows.
    test "the retirement record survives a step reclaimed after the sync ran" do
      app = routed_deployment("keep.example.test")

      {:ok, _} =
        Networking.create_domain(%{fqdn: "stale.example.test", deployment_id: app.id})

      {_release, s} = persisted_step(app, :sync_domain)

      assert {:ok, _discarded} = SyncDomain.run(s, ctx(app))
      assert [%{"fqdn" => "stale.example.test"}] = reread(s).resource_handle["retired"]

      # The re-run sees nothing left to retire and must not erase the account.
      assert {:ok, handle} = SyncDomain.run(reread(s), ctx(app))
      assert [%{"fqdn" => "stale.example.test"}] = handle["retired"]
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
      {:ok, handle} = PublishDns.run(step(%{}), ctx(app))

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

      assert :ok = PublishDns.compensate(step(handle), ctx(app))

      assert [survivor] = Networking.list_dns_records_for_deployment(app.id)
      assert survivor.managed == false
    end

    # `run/2` UPSERTS, so it is not the only writer of the rows it touches; `managed:
    # true` is set unconditionally on every record of every release and distinguishes
    # homelab-written from operator-hand-made, not release-2's rows from release-1's.
    # Compensating through `cleanup_deployment_dns_records/1` therefore deleted every
    # managed record the DEPLOYMENT holds, including ones this step never wrote.
    #
    # The domain move is where that is unambiguous: release 1 publishes `old`, the
    # operator moves the name, release 2 publishes `new` and rolls back. The `old`
    # records are not release 2's to destroy — they are still the deployment's only
    # resolving name, and the world is still cached against them.
    test "compensate removes only the records this step actually wrote" do
      stub_dns_provider()
      app = routed_deployment("old.example.test")

      {:ok, _first} = PublishDns.run(step(%{}), ctx(app))
      old_ids = app.id |> Networking.list_dns_records_for_deployment() |> Enum.map(& &1.id)
      assert old_ids != []

      {:ok, _} = Deployments.update_deployment(app, %{domain: "new.example.test"})
      moved = Deployments.get_deployment!(app.id)

      {:ok, second} = PublishDns.run(step(%{}), ctx(moved))
      assert :ok = PublishDns.compensate(step(second), ctx(moved))

      surviving = app.id |> Networking.list_dns_records_for_deployment() |> Enum.map(& &1.id)
      assert Enum.sort(surviving) == Enum.sort(old_ids)
    end

    # The other half of "only what this step recorded": a record re-pointed at another
    # deployment between the write and the undo is no longer ours, even though its id is
    # still in our handle.
    test "compensate leaves a record that now belongs to another deployment" do
      stub_dns_provider()
      app = routed_deployment("moved.example.test")
      other = routed_deployment("elsewhere.example.test")

      {:ok, handle} = PublishDns.run(step(%{}), ctx(app))

      for record <- Networking.list_dns_records_for_deployment(app.id) do
        {:ok, _} = Networking.update_dns_record(record, %{deployment_id: other.id})
      end

      assert :ok = PublishDns.compensate(step(handle), ctx(app))
      assert Networking.list_dns_records_for_deployment(other.id) != []
    end

    # A reclaimed step re-runs from scratch, and it may write a DIFFERENT set of rows
    # than its first attempt did — the operator moved the domain in between, and
    # `ensure_deployment_dns_records/2` publishes the CURRENT name without retiring the
    # previous one. Both sets are this step's, so both are its to undo. Overwriting
    # `record_ids` on the re-run would drop the first set and leave exactly the
    # externally-cached orphan the rollback reported as removed.
    test "compensation covers records written by an earlier attempt of the same step" do
      stub_dns_provider()
      app = routed_deployment("attempt-one.example.test")
      {_release, s} = persisted_step(app, :publish_dns)

      assert {:ok, _} = PublishDns.run(s, ctx(app))
      first_ids = app.id |> Networking.list_dns_records_for_deployment() |> Enum.map(& &1.id)
      assert first_ids != []

      {:ok, _} = Deployments.update_deployment(app, %{domain: "attempt-two.example.test"})
      moved = Deployments.get_deployment!(app.id)

      assert {:ok, handle} = PublishDns.run(reread(s), ctx(moved))
      assert Enum.all?(first_ids, &(&1 in handle["record_ids"]))

      assert :ok = PublishDns.compensate(step(handle), ctx(moved))
      assert Networking.list_dns_records_for_deployment(app.id) == []
    end

    # A compensation that could not reach the provider has undone nothing externally.
    # Reporting `:ok` there is exactly the "orphan nothing can ever clean up" this
    # module's own moduledoc claims the design prevents: the release settles
    # `:rolled_back`, the operator is told the world is clean, and the A record is still
    # live at Cloudflare pointing at a container that no longer exists.
    test "compensate fails when the provider refuses the deletion" do
      stub_dns_provider()
      app = routed_deployment("stuck.example.test")

      {:ok, handle} = PublishDns.run(step(%{}), ctx(app))

      stub(Homelab.Mocks.DnsProvider, :delete_record, fn _zone, _id ->
        {:error, {:api_error, 500, "nope"}}
      end)

      assert {:error, _reason} = PublishDns.compensate(step(handle), ctx(app))

      # And the local rows are kept, so a retry still knows what to delete.
      assert Networking.list_dns_records_for_deployment(app.id) != []
    end
  end

  describe "the imperative path is unchanged" do
    # The whole tier is additive: `deploy_now/1` keeps its own copies of these hooks
    # and keeps working. `detect_ip_config/0` is the one thing they now SHARE, so the
    # saga and the imperative path cannot publish two different addresses for the same
    # deployment.
    #
    # Asserted against the VALUE that reaches the record, not against the shape of the
    # map. The earlier version of this test read `detect_ip_config/0` and checked it had
    # an `:internal_ip` equal to its `:public_ip` — true of the function whether or not
    # anything calls it, so hardcoding an address in `PublishDns.run/2` left it green
    # and the drift it exists to prevent went unmeasured.
    test "detect_ip_config/0 is the address the saga actually publishes" do
      stub_dns_provider()
      expected = Deployments.detect_ip_config()
      assert expected.internal_ip == expected.public_ip
      assert is_binary(expected.internal_ip)

      app = routed_deployment("shared-ip.example.test")
      assert {:ok, _} = PublishDns.run(step(%{}), ctx(app))

      values =
        app.id
        |> Networking.list_dns_records_for_deployment()
        |> Enum.map(& &1.value)
        |> Enum.uniq()

      assert values == [expected.internal_ip]
    end
  end
end
