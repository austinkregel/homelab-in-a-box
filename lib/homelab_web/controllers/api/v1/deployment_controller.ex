defmodule HomelabWeb.Api.V1.DeploymentController do
  use HomelabWeb, :controller

  alias Homelab.Deployments

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, %{"space_id" => space_id}) do
    deployments = Deployments.list_deployments_for_tenant(space_id)
    render(conn, :index, deployments: deployments)
  end

  def create(conn, %{"space_id" => space_id, "deployment" => deployment_params}) do
    # "tenant_id" is the schema's field name, not the path's -- see `SpaceController`.
    attrs = Map.put(deployment_params, "tenant_id", space_id)

    with {:ok, deployment} <- Deployments.deploy_now(attrs) do
      conn
      |> put_status(:created)
      |> render(:show, deployment: deployment)
    end
  end

  def show(conn, %{"space_id" => space_id, "id" => id}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(space_id, id) do
      render(conn, :show, deployment: deployment)
    end
  end

  def update(conn, %{"space_id" => space_id, "id" => id, "deployment" => params}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(space_id, id),
         {:ok, updated} <- Deployments.update_deployment(deployment, params) do
      render(conn, :show, deployment: updated)
    end
  end

  def delete(conn, %{"space_id" => space_id, "id" => id}) do
    with {:ok, deployment} <- Deployments.get_deployment_for_tenant(space_id, id),
         {:ok, _} <- Deployments.destroy_deployment(deployment) do
      send_resp(conn, :no_content, "")
    end
  end
end
