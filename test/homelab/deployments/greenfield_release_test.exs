defmodule Homelab.Deployments.GreenfieldReleaseTest do
  @moduledoc """
  End-to-end greenfield release: the real step handlers (not the test double) run
  through `ReleaseRunner` against a mocked orchestrator. Covers the original bug —
  a multi-stage deploy must actually deploy the app and, on failure, roll the
  companion back rather than orphaning it.
  """
  use Homelab.DataCase, async: false

  # A third of the tests here drive a deliberate failure through the runner, and the
  # runner says so — `[release] N failed (...); rolling back`, plus the proxy's own
  # best-effort warning. What those tests assert on is the Activity log and the step
  # rows, not `Logger`, so the output is noise either way.
  @moduletag :capture_log

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{ReleaseFacts, ReleaseRunner, Releases}
  alias Homelab.Deployments.ReleaseSteps.EnsureDatastoreGrants

  setup :set_mox_global
  setup :verify_on_exit!

  defp clean_template(slug),
    do:
      insert(:app_template,
        slug: slug,
        required_env: [],
        default_env: %{},
        volumes: [],
        ports: []
      )

  defp pending_deployment(tenant, slug, attrs) do
    insert(
      :deployment,
      Keyword.merge(
        [tenant: tenant, app_template: clean_template(slug), status: :pending, external_id: nil],
        attrs
      )
    )
  end

  # `ensure_ingress_proxy` is position 0 of every routed plan, and the real
  # `Infrastructure.ensure_traefik/0` returns `{:error, :dns_token_missing}` here —
  # there is no DNS-01 token in the test env and no daemon behind it. Unstubbed, every
  # release below takes the step's best-effort failure branch, so the success branch
  # that gates each routed deploy is exercised end to end by nothing. The tests that are
  # ABOUT the proxy override this with the return each one needs.
  setup do
    Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:ok, :started} end)
    on_exit(fn -> Application.delete_env(:homelab, :ingress_proxy_ensurer) end)
    :ok
  end

  setup do
    tenant = insert(:tenant, slug: "acme")
    app = pending_deployment(tenant, "app", domain: "app.acme.test")
    companion = pending_deployment(tenant, "db", domain: nil)
    %{app: app, companion: companion}
  end

  test "deploy_release plans companion-then-app steps with ingress", %{
    app: app,
    companion: companion
  } do
    {:ok, release} = Deployments.deploy_release(app, [companion])
    types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

    # The proxy before any container exists; everything that advertises a name after
    # the app's health gate.
    assert types == [
             :ensure_ingress_proxy,
             :provision_credentials,
             :dependency_container,
             :await_health,
             :ensure_datastore_grants,
             :app_container,
             :await_health,
             :sync_domain,
             :publish_dns,
             :publish_ingress,
             :verify_public_url
           ]

    assert release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.stage) == [
             :prepare,
             :prepare,
             :dependencies,
             :dependencies,
             :dependencies,
             :workload,
             :workload,
             :naming,
             :naming,
             :reachability,
             :verification
           ]
  end

  # The same plan whatever the deployment looks like: a domainless app with no
  # companions still gets every singleton stage.
  test "the singleton stages are planned for a deployment that needs none of them" do
    tenant = insert(:tenant, slug: "bare")
    app = pending_deployment(tenant, "bare-app", domain: nil)

    {:ok, release} = Deployments.deploy_release(app)

    assert release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type) == [
             :ensure_ingress_proxy,
             :provision_credentials,
             :app_container,
             :await_health,
             :sync_domain,
             :publish_dns,
             :publish_ingress,
             :verify_public_url
           ]
  end

  # `EnsureDatastoreGrants` was registered in config, fully implemented, tested at the
  # SQL level — and no planner emitted it, so `Grants.reconcile/1` had exactly one caller
  # and that caller was unreachable. The bug it exists for is quiet: a datastore whose
  # volume already holds data ignores MARIADB_USER/PASSWORD (the image's init runs once,
  # on an empty data dir), so the app is handed a password the database never took, the
  # release still reaches `:running` because AwaitHealth only checks container health,
  # and the failure surfaces later as `Access denied` from inside the app.
  #
  # The assertion above froze the omission: it lists the step types verbatim.
  test "a datastore companion gets its grants reconciled before the app starts", %{
    app: app,
    companion: companion
  } do
    {:ok, _} =
      Homelab.Catalog.update_app_template(companion.app_template, %{image: "mariadb:11"})

    companion = Deployments.get_deployment!(companion.id)

    {:ok, release} = Deployments.deploy_release(app, [companion])
    steps = Enum.sort_by(release.steps, & &1.position)
    types = Enum.map(steps, & &1.type)

    assert :ensure_datastore_grants in types

    grants = Enum.find(steps, &(&1.type == :ensure_datastore_grants))

    assert grants.resource_handle == %{
             "deployment_id" => companion.id,
             "app_deployment_id" => app.id
           }

    # After the datastore is healthy, before the app container is created.
    assert grants.position > Enum.find(steps, &(&1.type == :await_health)).position
    assert grants.position < Enum.find(steps, &(&1.type == :app_container)).position
  end

  test "a companion that is not a datastore skips its grants step", %{
    app: app,
    companion: companion
  } do
    # `clean_template/1` uses a plain image, so the handler declines rather than the
    # plan quietly differing.
    {:ok, release} = Deployments.deploy_release(app, [companion])
    step = Enum.find(release.steps, &(&1.type == :ensure_datastore_grants))

    assert {:skip, reason} =
             EnsureDatastoreGrants.skip?(step, %{facts: ReleaseFacts.build(companion)})

    assert reason =~ "not a datastore"
  end

  # `Access.effective_exposure/1` needs the template, and facts preload before they
  # evaluate anything — as `publish_deployment/1` does with the same struct.
  test "facts tolerate a deployment loaded without its associations", %{app: app} do
    bare = Repo.get!(Homelab.Deployments.Deployment, app.id)
    assert %Ecto.Association.NotLoaded{} = bare.app_template

    assert :ok = Deployments.publish_deployment(bare)

    facts = ReleaseFacts.build(bare)
    assert facts.ingress_published?
    assert facts.attachable?

    assert {:ok, release} = Deployments.deploy_release(bare)
    assert :publish_ingress in Enum.map(release.steps, & &1.type)
  end

  test "an app with no domain skips reachability at runtime rather than at plan time", %{
    companion: companion
  } do
    tenant = insert(:tenant, slug: "nodomain")
    app = pending_deployment(tenant, "app2", domain: nil)

    running_stack()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    step =
      release.id
      |> Releases.get_release()
      |> Map.fetch!(:steps)
      |> Enum.find(&(&1.type == :publish_ingress))

    assert step.status == :skipped
    assert step.reason_type == "skipped"
    assert step.reason_message =~ "not proxy-routed"
  end

  # A DNS provider IS configured in test, so `publish_dns` really pushes. Stubbing it
  # here rather than per-test keeps the failures below about the saga, not about Mox.
  defp stub_dns_provider do
    stub(Homelab.Mocks.DnsProvider, :list_records, fn _zone -> {:ok, []} end)
    stub(Homelab.Mocks.DnsProvider, :create_record, fn _zone, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :update_record, fn _zone, _id, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :delete_record, fn _zone, _id -> :ok end)
  end

  # The fail-safe, independent of any one driver. A template that declares a healthcheck
  # must not become un-deployable just because the orchestrator cannot report health:
  # `AwaitHealth` required `:healthy` outright, so a driver answering `:none` held the
  # gate until it timed out and the release rolled back a workload that was up.
  #
  # This was live on Swarm — health hardcoded `:none` — but the bug is in the gate, not
  # the driver, and it would return with the next orchestrator that cannot answer.
  # `:starting` and `:unhealthy` still hold the gate; only "cannot say" degrades.
  test "a declared healthcheck still deploys when the driver cannot report health", %{
    app: app,
    companion: companion
  } do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :none}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    assert Releases.get_release(release.id).status == :running
  end

  # ...but an unreportable health does NOT mean "assume it is up". A driver that says
  # nothing about health and reports the workload as not running must still hold the gate,
  # or the degradation becomes a way to pass every check.
  test "an unreportable health still fails when the workload is not running", %{
    app: app,
    companion: companion
  } do
    # The gate is SUPPOSED to hold here, so it will poll until its deadline. Shorten it,
    # or this asserts nothing and reports an ExUnit timeout 60s later — which is how it
    # failed the first time I wrote it.
    Application.put_env(:homelab, :await_health_timeout_ms, 30)
    Application.put_env(:homelab, :await_health_interval_ms, 5)

    on_exit(fn ->
      Application.delete_env(:homelab, :await_health_timeout_ms)
      Application.delete_env(:homelab, :await_health_interval_ms)
    end)

    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :failed, health: :none}}
    end)

    stub(Homelab.Mocks.Orchestrator, :undeploy, fn _ -> :ok end)
    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    ReleaseRunner.run(release.id, owner: "t")

    refute Releases.get_release(release.id).status == :running
  end

  test "happy path deploys companion + app and lands the release :running", %{
    app: app,
    companion: companion
  } do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    release = Releases.get_release(release.id)
    assert release.status == :running
    # Every step settled: the ones that applied completed, the rest recorded a skip.
    assert Enum.all?(release.steps, &(&1.status in [:completed, :skipped]))
    assert Enum.any?(release.steps, &(&1.status == :completed))

    assert Deployments.get_deployment!(companion.id).external_id == "ext-#{companion.id}"
    assert Deployments.get_deployment!(app.id).external_id == "ext-#{app.id}"
  end

  # `do_deploy/1` created the Domain row and the A records in `post_deploy_hooks/1`;
  # the saga did neither, so a release-deployed app was routed by Traefik but had no
  # Domain row (no exposure for the access layer, no TLS state, nothing on the Domains
  # page) and no name resolving to it. Both were silently absent — the release still
  # reported `:running`.
  test "a routed release persists the Domain row and the DNS records", %{app: app} do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app)
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    assert {:ok, domain} = Homelab.Networking.get_domain_by_fqdn("app.acme.test")
    assert domain.deployment_id == app.id

    records = Homelab.Networking.list_dns_records_for_deployment(app.id)
    assert records != []
    assert Enum.all?(records, & &1.managed)
  end

  # A DNS A record is the one artifact here that is externally visible and cached by
  # resolvers: left behind, it points the world at a container that no longer exists.
  # The Domain row goes too, but ONLY because this release is what created it — a
  # reclaimed row belongs to whoever had it first.
  test "a rollback removes the DNS records and the Domain row it created", %{app: app} do
    app_spec_id = to_string(app.id)

    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    # Reachability is the last step and it is what fails, so everything before it —
    # including the domain row and the records — has to be walked back.
    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> {:error, :boom} end)
    stub(Homelab.Mocks.Orchestrator, :unpublish, fn _, _ -> :ok end)
    stub(Homelab.Mocks.Orchestrator, :undeploy, fn "ext-" <> ^app_spec_id -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app)
    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")

    assert Homelab.Networking.list_dns_records_for_deployment(app.id) == []
    assert {:error, :not_found} = Homelab.Networking.get_domain_by_fqdn("app.acme.test")
  end

  # The other half of that rule: a row this release only RECLAIMED predates it, and
  # deleting it on rollback would destroy state (TLS status, zone link, another
  # deployment's claim) the release never owned.
  test "a rollback leaves a Domain row it merely reclaimed", %{app: app, companion: companion} do
    app_spec_id = to_string(app.id)

    # The row predates this release and belongs to someone else.
    {:ok, _pre_existing} =
      Homelab.Networking.create_domain(%{
        fqdn: "app.acme.test",
        deployment_id: companion.id,
        exposure_mode: :public
      })

    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> {:error, :boom} end)
    stub(Homelab.Mocks.Orchestrator, :unpublish, fn _, _ -> :ok end)
    stub(Homelab.Mocks.Orchestrator, :undeploy, fn "ext-" <> ^app_spec_id -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app)
    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")

    assert {:ok, _still_there} = Homelab.Networking.get_domain_by_fqdn("app.acme.test")
  end

  # The saga wrote nothing to the Activity page, so every deployment made through a
  # release had no history at all while every `deploy_now/1` deployment did. Entries
  # hang off the runner's compare-and-set transitions, which is what makes them
  # once-only across a resume — and a companion's entry files under the COMPANION,
  # because that is what the Activity page filters on.
  test "a release writes Activity entries, attributed per deployment", %{
    app: app,
    companion: companion
  } do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    entries = Homelab.Services.ActivityLog.recent(200)
    for_deployment = fn id -> Enum.filter(entries, &(&1.metadata[:deployment_id] == id)) end

    assert Enum.any?(for_deployment.(app.id), &(&1.message =~ "release started"))
    assert Enum.any?(for_deployment.(app.id), &(&1.message =~ "deployed"))
    assert Enum.any?(for_deployment.(companion.id), &(&1.message =~ "deployed"))
  end

  # The failure half of the same deliverable shipped untested — `grep -rn 'rolling
  # back\|rollback FAILED\|release failed' test/` returned nothing at all. Which is the
  # half that matters: a successful deploy is visible on the deployment page anyway,
  # while a rollback is the case where the Activity feed is the ONLY place an operator
  # can find out what happened and to which deployment.
  test "a failed release writes the rollback Activity entries", %{
    app: app,
    companion: companion
  } do
    app_spec_id = to_string(app.id)

    stub(Homelab.Mocks.Orchestrator, :deploy, fn
      %{deployment_id: ^app_spec_id} -> {:error, :boom}
      spec -> {:ok, "ext-" <> spec.deployment_id}
    end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :undeploy, fn _id -> :ok end)
    stub_dns_provider()

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")

    entries = Homelab.Services.ActivityLog.recent(100)
    for_app = Enum.filter(entries, &(&1.metadata[:deployment_id] == app.id))

    # The release-level transition into compensation, carrying the reason.
    assert Enum.any?(
             for_app,
             &(&1.level == :error and &1.message =~ "release failed, rolling back" and
                 &1.message =~ "boom")
           )

    # The step that failed, named, and filed under the deployment it was deploying.
    assert Enum.any?(
             for_app,
             &(&1.level == :error and &1.message =~ "app_container failed")
           )

    # And the settle, so the feed does not stop at "rolling back" forever.
    assert Enum.any?(for_app, &(&1.level == :error and &1.message =~ "release rolled back"))
  end

  test "app failure rolls back and undeploys the companion (no orphan)", %{
    app: app,
    companion: companion
  } do
    test_pid = self()
    app_spec_id = to_string(app.id)

    # Companion deploys fine; the app deploy fails.
    stub(Homelab.Mocks.Orchestrator, :deploy, fn
      %{deployment_id: ^app_spec_id} -> {:error, :boom}
      spec -> {:ok, "ext-" <> spec.deployment_id}
    end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    # Compensation must undeploy the companion that was already created.
    stub(Homelab.Mocks.Orchestrator, :undeploy, fn id ->
      send(test_pid, {:undeployed, id})
      :ok
    end)

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")

    release = Releases.get_release(release.id)
    assert release.status == :rolled_back

    # The companion's container was torn back down, and its row cleared — no orphan.
    assert_received {:undeployed, ext}
    assert ext == "ext-#{companion.id}"
    assert Deployments.get_deployment!(companion.id).external_id == nil
  end

  # --- EnsureIngressProxy: registration, and the signal when it cannot ensure ---

  defp running_stack do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec -> {:ok, "ext-" <> spec.deployment_id} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :publish, fn _, _ -> :ok end)
    stub_dns_provider()
  end

  defp proxy_step(release_id) do
    release_id
    |> Releases.get_release()
    |> Map.fetch!(:steps)
    |> Enum.find(&(&1.type == :ensure_ingress_proxy))
  end

  # An unregistered step type falls through to `NoopHandler`, which logs and succeeds.
  # So deleting the `:ensure_ingress_proxy` line from `config/config.exs` left the whole
  # suite green while no release ensured a proxy again: the step is still planned, still
  # runs, still completes. Nothing that only looks at plans or statuses can tell the
  # difference.
  #
  # The handle is what can: `NoopHandler` writes `%{"noop" => true, "type" => ...}`,
  # `EnsureIngressProxy` writes `"ingress_proxy"`.
  test "the ensure_ingress_proxy step runs its registered handler, not the noop fallback",
       %{app: app} do
    running_stack()

    {:ok, release} = Deployments.deploy_release(app)
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    step = proxy_step(release.id)
    assert step.status == :completed
    refute step.resource_handle["noop"]
    # The exact branch, not "one of the three it might write": the ensurer is stubbed
    # to start the proxy, so anything else means the success path did not run.
    assert step.resource_handle["ingress_proxy"] == "started"
  end

  # `EnsureIngressProxy` deliberately never fails the release: `ensure_traefik/0` returns
  # `{:error, :dns_token_missing}` on any install without a DNS-01 token, which is normal
  # for a LAN-only homelab, and hard-failing would make every routed deploy impossible
  # there. That argument survives — but it leaves a `:running` release for a route no
  # plane-managed proxy is serving, and the only trace was an ActivityLog warn in a
  # 100-entry ring buffer plus a `resource_handle` key nothing renders. The release card
  # showed "ensure ingress proxy · completed" and nothing else.
  #
  # So the reason is recorded on the step row itself, in the field the card already
  # renders under a step. Scoped to the release that has the problem, and it ages out of
  # nothing.
  test "an unavailable proxy leaves its reason on the step, not only in a log", %{app: app} do
    Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:error, :dns_token_missing} end)
    on_exit(fn -> Application.delete_env(:homelab, :ingress_proxy_ensurer) end)

    running_stack()

    {:ok, release} = Deployments.deploy_release(app)
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    step = proxy_step(release.id)

    # Still not a failure — the release is green and every container was created.
    assert step.status == :completed
    assert Releases.get_release(release.id).status == :running

    # But the release says WHY the route may not resolve.
    assert step.reason_message =~ "Traefik not ensured"
    assert step.reason_message =~ "dns_token_missing"
  end

  # The other side of it: an install that HAS a proxy gets no note, so the note means
  # something when it is there.
  test "a proxy that was already running leaves no note", %{app: app} do
    Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:ok, :already_running} end)
    on_exit(fn -> Application.delete_env(:homelab, :ingress_proxy_ensurer) end)

    running_stack()

    {:ok, release} = Deployments.deploy_release(app)
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    step = proxy_step(release.id)
    assert step.resource_handle["ingress_proxy"] == "already_running"
    assert step.reason_message == nil
  end
end
