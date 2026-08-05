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
end
