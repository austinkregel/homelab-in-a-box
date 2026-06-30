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

    stub(Homelab.Mocks.Orchestrator, :publish, fn _net -> :ok end)

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
