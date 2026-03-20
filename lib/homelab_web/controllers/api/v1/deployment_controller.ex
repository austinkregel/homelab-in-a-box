defmodule HomelabWeb.Api.V1.DeploymentController do
  use HomelabWeb, :controller

  alias Homelab.Deployments

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, %{"tenant_id" => tenant_id}) do
    deployments = Deployments.list_deployments_for_tenant(tenant_id)
    render(conn, :index, deployments: deployments)
  end

  def create(conn, %{"tenant_id" => tenant_id, "deployment" => deployment_params}) do
    attrs = Map.put(deployment_params, "tenant_id", tenant_id)

    with {:ok, deployment} <- Deployments.deploy_now(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, deployment: deployment)
    end
  end

  def show(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(tenant_id, id) do
      render(conn, :show, deployment: deployment)
    end
  end

  def update(conn, %{"tenant_id" => tenant_id, "id" => id, "deployment" => params}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(tenant_id, id),
         {:ok, updated} <- Deployments.update_deployment(deployment, params) do
      render(conn, :show, deployment: updated)
    end
  end

  def delete(conn, %{"tenant_id" => tenant_id, "id" => id}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(tenant_id, id),
         {:ok, _} <- Deployments.destroy_deployment(deployment) do
      send_resp(conn, :no_content, "")
    end
  end
end
