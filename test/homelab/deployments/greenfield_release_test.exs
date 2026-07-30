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

    assert types == [
             :dependency_container,
             :await_health,
             :app_container,
             :await_health,
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

  test "no ingress step when the app has no domain", %{companion: companion} do
    tenant = insert(:tenant, slug: "nodomain")
    app = pending_deployment(tenant, "app2", domain: nil)

    {:ok, release} = Deployments.deploy_release(app, [companion])
    refute :publish_ingress in Enum.map(release.steps, & &1.type)
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

    {:ok, release} = Deployments.deploy_release(app, [companion])
    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    release = Releases.get_release(release.id)
    assert release.status == :running
    assert Enum.all?(release.steps, &(&1.status == :completed))

    assert Deployments.get_deployment!(companion.id).external_id == "ext-#{companion.id}"
    assert Deployments.get_deployment!(app.id).external_id == "ext-#{app.id}"
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
