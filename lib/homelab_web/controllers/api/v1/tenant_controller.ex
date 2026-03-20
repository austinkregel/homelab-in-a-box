defmodule HomelabWeb.Api.V1.TenantController do
  use HomelabWeb, :controller

  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, _params) do
    tenants = Tenants.list_tenants()
    render(conn, :index, tenants: tenants)
  end

  def create(conn, %{"tenant" => tenant_params}) do
    with {:ok, %Tenant{} = tenant} <- Tenants.create_tenant(tenant_params) do
      conn
      |> put_status(:created)
      |> render(:show, tenant: tenant)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, tenant} <- Tenants.get_tenant(id) do
      render(conn, :show, tenant: tenant)
    end
  end

  def update(conn, %{"id" => id, "tenant" => tenant_params}) do
    with {:ok, tenant} <- Tenants.get_tenant(id),
         {:ok, updated} <- Tenants.update_tenant(tenant, tenant_params) do
      render(conn, :show, tenant: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, tenant} <- Tenants.get_tenant(id),
         {:ok, _} <- Tenants.delete_tenant(tenant) do
      send_resp(conn, :no_content, "")
    end
  end
end
