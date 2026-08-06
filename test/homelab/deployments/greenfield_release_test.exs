defmodule Homelab.Deployments.GreenfieldReleaseTest do
  @moduledoc """
  End-to-end greenfield release: the real step handlers (not the test double) run
  through `ReleaseRunner` against a mocked orchestrator. Covers the original bug —
  a multi-stage deploy must actually deploy the app and, on failure, roll the
  companion back rather than orphaning it.
  """
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{ReleaseRunner, Releases}

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

    # The full routed plan. The proxy is ensured BEFORE any container exists (it is a
    # precondition of the route, and failing there means there is nothing to unwind);
    # everything that advertises a name — the Domain row, the A records, reachability —
    # comes after the app's health gate, so nothing points at a workload that is not up.
    assert types == [
             :ensure_ingress_proxy,
             :dependency_container,
             :await_health,
             :app_container,
             :await_health,
             :sync_domain,
             :publish_dns,
             :publish_ingress
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

  test "a companion that is not a datastore gets no grants step", %{
    app: app,
    companion: companion
  } do
    # `clean_template/1` uses a plain image; only engines Grants can actually drive are
    # planned, rather than emitting a step that would fail.
    {:ok, release} = Deployments.deploy_release(app, [companion])

    refute :ensure_datastore_grants in Enum.map(release.steps, & &1.type)
  end

  # `reachability_steps/1` reuses `publish_deployment/1`'s runtime gate, and that gate
  # opens with `Repo.preload(deployment, [:tenant, :app_template])` BEFORE it evaluates
  # `ingress_published?/1 and attachable?/1`. Restating the predicates on the caller's
  # struct without the preload added a precondition `deploy_release/2` never had — the
  # pre-image was a pure `domain` field match — and fails it by RAISING, where the gate
  # it copied returns `:ok` for the very same struct.
  test "planning tolerates a deployment loaded without its associations", %{app: app} do
    bare = Repo.get!(Homelab.Deployments.Deployment, app.id)
    assert %Ecto.Association.NotLoaded{} = bare.app_template

    # The gate this predicate was copied from is fine with it.
    assert :ok = Deployments.publish_deployment(bare)

    assert {:ok, release} = Deployments.deploy_release(bare)
    assert :publish_ingress in Enum.map(release.steps, & &1.type)
  end

  test "no ingress step when the app has no domain", %{companion: companion} do
    tenant = insert(:tenant, slug: "nodomain")
    app = pending_deployment(tenant, "app2", domain: nil)

    {:ok, release} = Deployments.deploy_release(app, [companion])
    refute :publish_ingress in Enum.map(release.steps, & &1.type)
  end

  # A DNS provider IS configured in test, so `publish_dns` really pushes. Stubbing it
  # here rather than per-test keeps the failures below about the saga, not about Mox.
  defp stub_dns_provider do
    stub(Homelab.Mocks.DnsProvider, :list_records, fn _zone -> {:ok, []} end)
    stub(Homelab.Mocks.DnsProvider, :create_record, fn _zone, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :update_record, fn _zone, _id, _rec -> {:ok, %{id: "rec"}} end)

    stub(Homelab.Mocks.DnsProvider, :delete_record, fn _zone, _id -> :ok end)
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
    assert Enum.all?(release.steps, &(&1.status == :completed))

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
end
