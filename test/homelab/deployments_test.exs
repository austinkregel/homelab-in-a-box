defmodule Homelab.DeploymentsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Deployments
  alias Homelab.Deployments.Deployment
  import Homelab.Factory

  describe "list_deployments/0" do
    test "returns all deployments with preloaded associations" do
      insert(:deployment)
      insert(:deployment)

      deployments = Deployments.list_deployments()
      assert length(deployments) == 2
      assert hd(deployments).tenant != nil
      assert hd(deployments).app_template != nil
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
  end

  describe "list_desired_states/0" do
    test "returns deployments that should be running" do
      insert(:deployment, status: :pending)
      insert(:deployment, status: :running)
      insert(:deployment, status: :failed)
      insert(:deployment, status: :stopped)
      insert(:deployment, status: :removing)

      desired = Deployments.list_desired_states()
      assert length(desired) == 3

      statuses = Enum.map(desired, & &1.status)
      assert :pending in statuses
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
      assert {:error, :not_found} = Deployments.get_deployment(999)
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
    end

    test "returns error with missing required fields" do
      assert {:error, changeset} = Deployments.create_deployment(%{})
      assert errors_on(changeset).tenant_id != []
      assert errors_on(changeset).app_template_id != []
    end

    test "allows multiple deployments of same template in same tenant" do
      tenant = insert(:tenant)
      template = insert(:app_template)
      insert(:deployment, tenant: tenant, app_template: template)

      attrs = %{tenant_id: tenant.id, app_template_id: template.id}
      assert {:ok, _deployment} = Deployments.create_deployment(attrs)
    end
  end

  describe "update_status/2" do
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
  end

  describe "delete_deployment/1" do
    test "deletes a deployment" do
      deployment = insert(:deployment)
      assert {:ok, _} = Deployments.delete_deployment(deployment)
      assert {:error, :not_found} = Deployments.get_deployment(deployment.id)
    end
  end
end
