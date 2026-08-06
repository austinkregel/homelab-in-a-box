defmodule Homelab.Deployments.CreateAndDeployReleaseTest do
  @moduledoc """
  `create_and_deploy_release/2` — the additive, durable replacement for
  `deploy_now/1`.

  `deploy_now/1` deploys imperatively inside the caller's request: no release row,
  no health gate, no ingress-after-healthy, no rollback. The saga has all of that,
  but replacing `deploy_now/1` with a bare `create_deployment` + `deploy_release`
  would lose the one thing the imperative path does better — it validates the spec
  BEFORE it commits to anything, and returns the reason to the caller who can still
  show it.
  """
  use Homelab.DataCase, async: false
  use Oban.Testing, repo: Homelab.ObanRepo

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.ReleaseRunner

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    tenant = insert(:tenant, slug: "acme")
    %{tenant: tenant}
  end

  defp clean_template(attrs \\ []) do
    insert(
      :app_template,
      Keyword.merge([required_env: [], default_env: %{}, volumes: [], ports: []], attrs)
    )
  end

  describe "create_and_deploy_release/2" do
    test "returns the deployment AND the release, and enqueues the runner", %{tenant: tenant} do
      template = clean_template()

      assert {:ok, %{deployment: deployment, release: release}} =
               Deployments.create_and_deploy_release(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id,
                 domain: "app.acme.test"
               })

      # Both, because every caller needs both: the deployment to navigate to, the
      # release to show progress against.
      assert deployment.id
      assert release.deployment_id == deployment.id
      assert release.status == :planning

      # The enqueue happens AFTER the transaction commits — Oban is on a separate
      # repo, so there is no transaction spanning both and enqueuing inside would
      # publish a job for a release that had not committed.
      assert_enqueued(worker: ReleaseRunner, args: %{"release_id" => release.id})
    end

    test "plans the full routed shape, proxy first and name-publishing last", %{tenant: tenant} do
      template = clean_template()

      {:ok, %{release: release}} =
        Deployments.create_and_deploy_release(%{
          tenant_id: tenant.id,
          app_template_id: template.id,
          domain: "routed.acme.test"
        })

      types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

      assert types == [
               :ensure_ingress_proxy,
               :app_container,
               :await_health,
               :sync_domain,
               :publish_dns,
               :publish_ingress
             ]
    end

    # THE point of the pre-flight. Without it the operator gets a green "deployment
    # started", is redirected to a release page, and the whole thing is rolled back a
    # few seconds later in the background with the reason buried in a step row.
    # `deploy_now/1` returns this in-request and the wizard flashes it; the replacement
    # has to do the same or it is a regression dressed as an upgrade.
    test "refuses in-request when the app's spec cannot be built", %{tenant: tenant} do
      template = clean_template(required_env: ["MUST_HAVE_KEY"])

      assert {:error, {:missing_required_env, ["MUST_HAVE_KEY"]}} =
               Deployments.create_and_deploy_release(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id
               })
    end

    # And it leaves NOTHING behind: create + plan share one transaction, so a
    # pre-flight failure rolls the deployment row back too. A half-created deployment
    # with no release is a row the reconciler skips forever.
    test "a failed pre-flight creates no deployment and no release", %{tenant: tenant} do
      template = clean_template(required_env: ["MUST_HAVE_KEY"])

      assert {:error, _} =
               Deployments.create_and_deploy_release(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id
               })

      assert Deployments.list_deployments() == []
      refute_enqueued(worker: ReleaseRunner)
    end

    # A companion is deployed by the same release, so an unbuildable companion fails
    # the release just as surely — and must be caught at the same seam, not three
    # steps into the saga after the app is already up.
    test "the pre-flight covers companions too", %{tenant: tenant} do
      companion =
        insert(:deployment,
          tenant: tenant,
          app_template: clean_template(required_env: ["DB_ROOT_PASSWORD"]),
          status: :pending,
          external_id: nil
        )

      assert {:error, {:missing_required_env, ["DB_ROOT_PASSWORD"]}} =
               Deployments.create_and_deploy_release(
                 %{tenant_id: tenant.id, app_template_id: clean_template().id},
                 [companion]
               )

      # The app row was rolled back with it; only the pre-existing companion remains.
      assert Enum.map(Deployments.list_deployments(), & &1.id) == [companion.id]
    end

    test "a changeset failure is returned as-is", %{tenant: _tenant} do
      assert {:error, %Ecto.Changeset{}} = Deployments.create_and_deploy_release(%{})
    end

    # The whole reason this exists: unlike `deploy_now/1`, nothing is deployed until
    # the runner drives the release. The orchestrator mock is deliberately unstubbed.
    test "does not touch the orchestrator in-request", %{tenant: tenant} do
      template = clean_template()

      assert {:ok, %{deployment: deployment}} =
               Deployments.create_and_deploy_release(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id
               })

      assert Deployments.get_deployment!(deployment.id).external_id == nil
      assert Deployments.get_deployment!(deployment.id).status == :pending
    end
  end

  # Every case above uses a plain deployment, and that is exactly why both of the
  # bugs below survived: the netns path is the one where `create_and_deploy_release/2`
  # both resolves an implicit companion AND depends on the release to establish a
  # precondition the pre-flight would otherwise assert.
  describe "create_and_deploy_release/2 in a network namespace" do
    setup %{tenant: tenant} do
      donor_template =
        insert(:app_template,
          name: "Gluetun",
          slug: "gluetun-#{System.unique_integer([:positive])}",
          required_env: [],
          default_env: %{},
          volumes: [],
          ports: [%{"internal" => 8000, "role" => "other"}],
          netns_donor_kind: "gluetun",
          exposure_mode: :service
        )

      %{donor_template: donor_template}
    end

    defp child_attrs(tenant, donor) do
      template =
        insert(:app_template,
          name: "Sonarr #{System.unique_integer([:positive])}",
          slug: "sonarr-#{System.unique_integer([:positive])}",
          required_env: [],
          default_env: %{},
          volumes: [],
          ports: [%{"internal" => 8989, "role" => "web"}],
          exposure_mode: :public
        )

      %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        network_parent_id: donor.id,
        domain: "sonarr.example.com"
      }
    end

    defp donor(tenant, template, external_id) do
      insert(:deployment,
        tenant: tenant,
        app_template: template,
        domain: nil,
        status: if(external_id, do: :running, else: :pending),
        external_id: external_id
      )
    end

    # `create_and_deploy_release/2` resolved the donor into `all_companions` and then
    # handed that list to the planner, which resolves the donor AGAIN and appends the
    # caller's companions to it. `netns_donor_companions/1` does not `uniq` and
    # `plan_release/3` inserts step specs verbatim, so the donor was planned twice.
    #
    # Two `:dependency_container` steps for one deployment is the orphan-container class
    # this tier exists to close: both write `external_id`, so only the second is
    # compensatable and the first container is stranded — or the second collides on
    # `service_name/2` and fails a release that should have succeeded.
    test "plans the netns donor exactly once", %{tenant: tenant, donor_template: dt} do
      donor = donor(tenant, dt, "gluetun-container-1")

      assert {:ok, %{release: release}} =
               Deployments.create_and_deploy_release(child_attrs(tenant, donor))

      donor_handle = %{"deployment_id" => donor.id}

      deps =
        Enum.filter(
          release.steps,
          &(&1.type == :dependency_container and
              &1.resource_handle == donor_handle)
        )

      assert length(deps) == 1

      waits =
        Enum.filter(
          release.steps,
          &(&1.type == :await_health and
              &1.resource_handle == donor_handle)
        )

      assert length(waits) == 1
    end

    # The pre-flight built the CHILD's spec, and `resolve_netns_donor/1` fails closed on
    # a donor with no container — which is precisely the state of a donor this same
    # release is about to deploy. So the transaction rolled back and the child was never
    # created, for the exact case the saga exists to handle. SpecBuilder's own comment
    # says release ordering is what normally prevents this; the pre-flight was asserting
    # a precondition the release establishes.
    test "creates a child whose donor this release has not deployed yet", %{
      tenant: tenant,
      donor_template: dt
    } do
      donor = donor(tenant, dt, nil)

      assert {:ok, %{deployment: child, release: release}} =
               Deployments.create_and_deploy_release(child_attrs(tenant, donor))

      assert child.network_parent_id == donor.id
      assert Deployments.get_deployment!(child.id)

      # ...and the plan is what makes it safe: the donor is deployed and awaited healthy
      # before the child's container is created against its id.
      types = release.steps |> Enum.sort_by(& &1.position) |> Enum.map(& &1.type)

      assert Enum.find_index(types, &(&1 == :dependency_container)) <
               Enum.find_index(types, &(&1 == :app_container))
    end

    # The relaxation must be surgical. `:missing_required_env` is checked BEFORE the
    # donor is resolved in `SpecBuilder.build/1`, so skipping a not-running donor costs
    # nothing — every other pre-flight failure still fails fast.
    test "still fails fast on missing env for a child of an undeployed donor", %{
      tenant: tenant,
      donor_template: dt
    } do
      donor = donor(tenant, dt, nil)

      template =
        insert(:app_template,
          slug: "needs-env-#{System.unique_integer([:positive])}",
          required_env: ["MUST_HAVE_KEY"],
          default_env: %{},
          volumes: [],
          ports: []
        )

      assert {:error, {:missing_required_env, ["MUST_HAVE_KEY"]}} =
               Deployments.create_and_deploy_release(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id,
                 network_parent_id: donor.id
               })
    end

    # And a donor that is genuinely absent is still a hard failure — the relaxation is
    # scoped to donors THIS release will deploy, not to netns errors in general.
    #
    # This drives the `{:halt, error}` branch through the only door that reaches it: a
    # caller-supplied COMPANION which is itself a netns child, whose donor is neither in
    # the companion set nor already running. The app cannot reach that branch —
    # `companion_set/2` puts the app's own resolved donor into `deployable` whenever
    # `network_parent_id` resolves — so the guard protects the companion list, and an
    # earlier version of this test asserted an FK failure from `create_deployment/1`
    # instead, returning before the pre-flight ever ran.
    test "still fails when a companion's donor is outside this release", %{
      tenant: tenant,
      donor_template: dt
    } do
      # Never deployed, and not in the companion set below.
      absent_donor = donor(tenant, dt, nil)

      {:ok, stranded_companion} =
        Deployments.create_deployment(child_attrs(tenant, absent_donor))

      assert {:error, {:netns_donor_not_running, donor_id}} =
               Deployments.create_and_deploy_release(
                 %{tenant_id: tenant.id, app_template_id: clean_template().id},
                 [Deployments.get_deployment!(stranded_companion.id)]
               )

      assert donor_id == absent_donor.id
    end
  end
end
