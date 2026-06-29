defmodule Homelab.DeploymentsTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.Deployment

  setup :set_mox_global
  setup :verify_on_exit!

  describe "list_deployments/0" do
    test "returns all deployments with preloaded associations" do
      insert(:deployment)
      insert(:deployment)

      deployments = Deployments.list_deployments()
      assert length(deployments) == 2
      assert hd(deployments).tenant != nil
      assert hd(deployments).app_template != nil
    end

    test "returns empty list when no deployments exist" do
      assert Deployments.list_deployments() == []
    end
  end

  describe "list_deployments_for_tenant/1" do
    test "returns only deployments for the given tenant" do
      tenant = insert(:tenant)
      other_tenant = insert(:tenant)
      insert(:deployment, tenant: tenant)
      insert(:deployment, tenant: tenant)
      insert(:deployment, tenant: other_tenant)

      deployments = Deployments.list_deployments_for_tenant(tenant.id)
      assert length(deployments) == 2
      assert Enum.all?(deployments, &(&1.tenant_id == tenant.id))
    end

    test "returns empty list when tenant has no deployments" do
      tenant = insert(:tenant)
      assert Deployments.list_deployments_for_tenant(tenant.id) == []
    end

    test "preloads app_template" do
      tenant = insert(:tenant)
      insert(:deployment, tenant: tenant)

      [deployment] = Deployments.list_deployments_for_tenant(tenant.id)
      assert deployment.app_template != nil
      assert deployment.app_template.name != nil
    end
  end

  describe "list_desired_states/0" do
    test "returns deployments with active statuses" do
      insert(:deployment, status: :pending)
      insert(:deployment, status: :deploying)
      insert(:deployment, status: :running)
      insert(:deployment, status: :failed)
      insert(:deployment, status: :stopped)
      insert(:deployment, status: :removing)

      desired = Deployments.list_desired_states()
      statuses = Enum.map(desired, & &1.status)

      assert length(desired) == 4
      assert :pending in statuses
      assert :deploying in statuses
      assert :running in statuses
      assert :failed in statuses
      refute :stopped in statuses
      refute :removing in statuses
    end
  end

  describe "get_deployment/1" do
    test "returns deployment with preloaded associations" do
      deployment = insert(:deployment)
      assert {:ok, found} = Deployments.get_deployment(deployment.id)
      assert found.id == deployment.id
      assert found.tenant != nil
      assert found.app_template != nil
    end

    test "returns error when not found" do
      assert {:error, :not_found} = Deployments.get_deployment(0)
    end
  end

  describe "get_deployment!/1" do
    test "returns deployment with preloaded associations" do
      deployment = insert(:deployment)
      found = Deployments.get_deployment!(deployment.id)
      assert found.id == deployment.id
      assert found.tenant != nil
      assert found.app_template != nil
    end

    test "raises when not found" do
      assert_raise Ecto.NoResultsError, fn ->
        Deployments.get_deployment!(0)
      end
    end
  end

  describe "get_deployment_for_tenant/2" do
    test "returns deployment scoped to tenant" do
      tenant = insert(:tenant)
      deployment = insert(:deployment, tenant: tenant)

      assert {:ok, found} = Deployments.get_deployment_for_tenant(tenant.id, deployment.id)
      assert found.id == deployment.id
    end

    test "returns error when deployment belongs to different tenant" do
      tenant = insert(:tenant)
      other_tenant = insert(:tenant)
      deployment = insert(:deployment, tenant: other_tenant)

      assert {:error, :not_found} =
               Deployments.get_deployment_for_tenant(tenant.id, deployment.id)
    end
  end

  describe "create_deployment/1" do
    test "creates a deployment with valid attrs" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: "app.friends.homelab.local"
      }

      assert {:ok, %Deployment{} = deployment} = Deployments.create_deployment(attrs)
      assert deployment.status == :pending
      assert deployment.tenant_id == tenant.id
      assert deployment.app_template_id == template.id
      assert deployment.domain == "app.friends.homelab.local"
    end

    test "preloads tenant and app_template on created deployment" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      attrs = %{tenant_id: tenant.id, app_template_id: template.id}
      assert {:ok, deployment} = Deployments.create_deployment(attrs)
      assert deployment.tenant.id == tenant.id
      assert deployment.app_template.id == template.id
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Deployments.create_deployment(%{})
      assert errors_on(changeset).tenant_id != []
      assert errors_on(changeset).app_template_id != []
    end

    test "creates deployment with env_overrides" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        env_overrides: %{"CUSTOM_VAR" => "value"}
      }

      assert {:ok, deployment} = Deployments.create_deployment(attrs)
      assert deployment.env_overrides == %{"CUSTOM_VAR" => "value"}
    end
  end

  describe "update_deployment/2" do
    test "updates deployment attributes" do
      deployment = insert(:deployment, status: :pending)

      assert {:ok, updated} =
               Deployments.update_deployment(deployment, %{
                 status: :running,
                 domain: "new.homelab.local"
               })

      assert updated.status == :running
      assert updated.domain == "new.homelab.local"
    end

    test "returns error with invalid data" do
      deployment = insert(:deployment)
      assert {:error, changeset} = Deployments.update_deployment(deployment, %{status: :bogus})
      assert errors_on(changeset).status != []
    end

    test "preloads associations after update" do
      deployment = insert(:deployment)
      assert {:ok, updated} = Deployments.update_deployment(deployment, %{status: :running})
      assert updated.tenant != nil
      assert updated.app_template != nil
    end
  end

  describe "update_status/2,3" do
    test "updates deployment status" do
      deployment = insert(:deployment, status: :pending)
      assert {:ok, updated} = Deployments.update_status(deployment, :deploying)
      assert updated.status == :deploying
    end

    test "updates status with external_id" do
      deployment = insert(:deployment, status: :pending)

      assert {:ok, updated} =
               Deployments.update_status(deployment, :deploying, external_id: "svc_123")

      assert updated.status == :deploying
      assert updated.external_id == "svc_123"
    end

    test "updates status with error message" do
      deployment = insert(:deployment, status: :deploying)

      assert {:ok, updated} =
               Deployments.update_status(deployment, :failed, error: "Container crashed")

      assert updated.status == :failed
      assert updated.error_message == "Container crashed"
    end
  end

  describe "mark_for_removal/1" do
    test "sets status to removing" do
      deployment = insert(:deployment, status: :running)
      assert {:ok, updated} = Deployments.mark_for_removal(deployment)
      assert updated.status == :removing
    end
  end

  describe "mark_reconciled/1" do
    test "sets last_reconciled_at to now" do
      deployment = insert(:deployment)
      assert {:ok, updated} = Deployments.mark_reconciled(deployment)
      assert updated.last_reconciled_at != nil
    end
  end

  describe "mark_unhealthy/1" do
    test "marks deployment as failed by external_id" do
      deployment = insert(:deployment, status: :running, external_id: "svc_123")
      {1, _} = Deployments.mark_unhealthy("svc_123")

      assert {:ok, found} = Deployments.get_deployment(deployment.id)
      assert found.status == :failed
    end

    test "returns zero updates for unknown external_id" do
      {0, _} = Deployments.mark_unhealthy("nonexistent_id")
    end
  end

  describe "delete_deployment/1" do
    test "deletes a deployment" do
      deployment = insert(:deployment)
      assert {:ok, _} = Deployments.delete_deployment(deployment)
      assert {:error, :not_found} = Deployments.get_deployment(deployment.id)
    end
  end

  describe "stop_deployment/1" do
    test "calls orchestrator.undeploy and sets status to stopped" do
      deployment = insert(:deployment, status: :running, external_id: "ext_123")

      Homelab.Mocks.Orchestrator
      |> expect(:undeploy, fn "ext_123" -> :ok end)

      assert {:ok, stopped} = Deployments.stop_deployment(deployment)
      assert stopped.status == :stopped
      assert stopped.external_id == nil
    end

    test "handles deployment with no external_id" do
      deployment = insert(:deployment, status: :pending, external_id: nil)

      assert {:ok, stopped} = Deployments.stop_deployment(deployment)
      assert stopped.status == :stopped
      assert stopped.external_id == nil
    end
  end

  describe "start_deployment/1" do
    test "builds spec, deploys, and sets status to deploying" do
      deployment = insert(:deployment, status: :stopped)

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "container_123"} end)

      assert {:ok, started} = Deployments.start_deployment(deployment)
      assert started.status == :deploying
      assert started.external_id == "container_123"
    end

    test "sets status to failed and returns error when orchestrator returns error" do
      deployment = insert(:deployment, status: :stopped)

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:error, "out of resources"} end)

      assert {:error, "out of resources"} = Deployments.start_deployment(deployment)

      failed = Deployments.get_deployment!(deployment.id)
      assert failed.status == :failed
      assert failed.error_message != nil
    end
  end

  describe "restart_deployment/1" do
    test "calls orchestrator.restart and sets status to deploying" do
      deployment = insert(:deployment, status: :running, external_id: "ext_123")

      Homelab.Mocks.Orchestrator
      |> expect(:restart, fn "ext_123" -> :ok end)

      assert {:ok, restarted} = Deployments.restart_deployment(deployment)
      assert restarted.status == :deploying
    end

    test "returns error when deployment has no external_id" do
      deployment = insert(:deployment, status: :pending, external_id: nil)

      assert {:error, :not_deployed} = Deployments.restart_deployment(deployment)
    end

    test "returns error when orchestrator restart fails" do
      deployment = insert(:deployment, status: :running, external_id: "ext_123")

      Homelab.Mocks.Orchestrator
      |> expect(:restart, fn "ext_123" -> {:error, "service not found"} end)

      assert {:error, :restart_failed} = Deployments.restart_deployment(deployment)
    end
  end

  describe "destroy_deployment/1" do
    test "calls orchestrator.undeploy and deletes the deployment" do
      deployment = insert(:deployment, status: :running, external_id: "ext_123")

      Homelab.Mocks.Orchestrator
      |> expect(:undeploy, fn "ext_123" -> :ok end)

      assert {:ok, _} = Deployments.destroy_deployment(deployment)
      assert {:error, :not_found} = Deployments.get_deployment(deployment.id)
    end

    test "deletes deployment even without external_id" do
      deployment = insert(:deployment, status: :pending, external_id: nil)

      assert {:ok, _} = Deployments.destroy_deployment(deployment)
      assert {:error, :not_found} = Deployments.get_deployment(deployment.id)
    end
  end

  describe "deploy_now/1" do
    test "creates deployment and deploys it" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "container_456"} end)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_dns"}} end)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: "myapp.tenant.homelab.local"
      }

      assert {:ok, deployment} = Deployments.deploy_now(attrs)
      assert deployment.status == :deploying
      assert deployment.external_id == "container_456"
    end

    test "returns error when creation fails" do
      assert {:error, _changeset} = Deployments.deploy_now(%{})
    end

    test "sets status to failed when orchestrator deploy fails" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:error, "image not found"} end)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: "fail.tenant.homelab.local"
      }

      assert {:error, "image not found"} = Deployments.deploy_now(attrs)

      [deployment] = Deployments.list_deployments()
      assert deployment.status == :failed
    end
  end

  describe "change_deployment/2" do
    test "returns a changeset" do
      deployment = insert(:deployment)
      changeset = Deployments.change_deployment(deployment, %{status: :running})
      assert %Ecto.Changeset{} = changeset
    end
  end

  describe "deploy_now/1 spec build failure" do
    test "sets status to failed when required env vars are missing" do
      tenant = insert(:tenant)
      template = insert(:app_template, required_env: ["MUST_HAVE_KEY"])

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id
      }

      assert {:error, {:missing_required_env, ["MUST_HAVE_KEY"]}} = Deployments.deploy_now(attrs)

      [deployment] = Deployments.list_deployments()
      assert deployment.status == :failed
      assert deployment.error_message =~ "missing_required_env"
    end
  end

  describe "deploy_now/1 without domain" do
    test "deploys successfully without triggering domain or DNS hooks" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec -> {:ok, "container_no_domain"} end)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: nil
      }

      assert {:ok, deployment} = Deployments.deploy_now(attrs)
      assert deployment.status == :deploying
      assert deployment.external_id == "container_no_domain"
    end
  end

  describe "recreate_deployment/1" do
    test "undeploys the old container and deploys a fresh one from the current config" do
      deployment = insert(:deployment, status: :running, external_id: "old-123")

      Homelab.Mocks.Orchestrator
      |> expect(:undeploy, fn "old-123" -> :ok end)
      |> expect(:deploy, fn _spec -> {:ok, "new-456"} end)

      assert {:ok, recreated} = Deployments.recreate_deployment(deployment)
      assert recreated.external_id == "new-456"
      assert recreated.status == :deploying
    end
  end

  describe "start_deployment/1 spec build failure" do
    test "sets status to failed when spec build fails" do
      template = insert(:app_template, required_env: ["NEEDED_VAR"])

      deployment =
        insert(:deployment, status: :stopped, app_template: template, env_overrides: %{})

      assert {:error, {:missing_required_env, ["NEEDED_VAR"]}} =
               Deployments.start_deployment(deployment)

      failed = Deployments.get_deployment!(deployment.id)
      assert failed.status == :failed
      assert failed.error_message =~ "missing_required_env"
    end
  end

  describe "transition_status/4 (guarded compare-and-set)" do
    test "applies the transition when the row is in an allowed from-state" do
      deployment = insert(:deployment, status: :deploying)

      assert {:ok, updated} =
               Deployments.transition_status(deployment, :running, [:pending, :deploying])

      assert updated.status == :running
    end

    test "is a no-op when the current status is not in from-states" do
      deployment = insert(:deployment, status: :running)

      assert {:noop, current} =
               Deployments.transition_status(deployment, :deploying, [:pending])

      assert current.status == :running
    end

    test "records error and external_id via opts" do
      deployment = insert(:deployment, status: :deploying)

      assert {:ok, updated} =
               Deployments.transition_status(deployment, :failed, [:deploying],
                 error: "boom",
                 external_id: "ext_1"
               )

      assert updated.status == :failed
      assert updated.error_message == "boom"
      assert updated.external_id == "ext_1"
    end
  end

  describe "deploy_now/1 race with the event stream" do
    test "a :running written mid-deploy is not clobbered back to :deploying" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      Homelab.Mocks.DnsProvider
      |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_dns"}} end)

      # Simulate the Docker `start`/health event landing while deploy/1 is still
      # in flight: the row is advanced to :running before deploy/1 returns.
      Homelab.Mocks.Orchestrator
      |> expect(:deploy, fn _spec ->
        [dep] = Deployments.list_deployments()
        {:ok, _} = Deployments.transition_status(dep, :running, [:pending, :deploying])
        {:ok, "container_race"}
      end)

      attrs = %{
        tenant_id: tenant.id,
        app_template_id: template.id,
        domain: "race.tenant.homelab.local"
      }

      assert {:ok, deployment} = Deployments.deploy_now(attrs)
      # The guarded write must NOT have demoted it back to :deploying...
      assert deployment.status == :running
      # ...and the container id is still persisted even though the guard no-op'd.
      assert deployment.external_id == "container_race"
    end
  end

  describe "publish_deployment/1 and unpublish_deployment/1" do
    test "ingress-published deployment connects/disconnects its network via the orchestrator" do
      tenant = insert(:tenant, slug: "acme")
      template = insert(:app_template, slug: "blog")

      deployment =
        insert(:deployment, tenant: tenant, app_template: template, domain: "blog.acme.test")

      net = "homelab_acme_blog_net"

      Homelab.Mocks.Orchestrator
      |> expect(:publish, fn ^net -> :ok end)
      |> expect(:unpublish, fn ^net -> :ok end)

      assert :ok = Deployments.publish_deployment(deployment)
      assert :ok = Deployments.unpublish_deployment(deployment)
    end

    test "internal-only (no domain) deployment never touches ingress" do
      deployment = insert(:deployment, domain: nil)

      # No publish/unpublish expectations set: a call would fail verify_on_exit!.
      assert :ok = Deployments.publish_deployment(deployment)
      assert :ok = Deployments.unpublish_deployment(deployment)
    end
  end
end
