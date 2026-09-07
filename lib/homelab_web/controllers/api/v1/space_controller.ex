defmodule HomelabWeb.Api.V1.SpaceController do
  @moduledoc """
  Spaces: the organizational grouping a deployment belongs to.

  The HTTP surface says "space"; the domain context behind it is still
  `Homelab.Tenants`, whose schema, table and `tenant_id` foreign keys keep the older
  name. "Tenant" claimed an isolation this app does not implement — there is no
  user<->space relationship, so every signed-in user sees every space — and the word
  is only accurate about persistence, where it is expensive to change: `homelab.tenant`
  is a label on every running container and the reconciler's orphan sweep reads it.
  """
  use HomelabWeb, :controller

  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant

  action_fallback HomelabWeb.Api.V1.FallbackController

  def index(conn, _params) do
    render(conn, :index, spaces: Tenants.list_tenants())
  end

  def create(conn, %{"space" => space_params}) do
    with {:ok, %Tenant{} = space} <- Tenants.create_tenant(space_params) do
      conn
      |> put_status(:created)
      |> render(:show, space: space)
    end
  end

  def show(conn, %{"id" => id}) do
    with {:ok, space} <- Tenants.get_tenant(id) do
      render(conn, :show, space: space)
    end
  end

  def update(conn, %{"id" => id, "space" => space_params}) do
    with {:ok, space} <- Tenants.get_tenant(id),
         {:ok, updated} <- Tenants.update_tenant(space, space_params) do
      render(conn, :show, space: updated)
    end
  end

  def delete(conn, %{"id" => id}) do
    with {:ok, space} <- Tenants.get_tenant(id),
         {:ok, _} <- Tenants.delete_tenant(space) do
      send_resp(conn, :no_content, "")
    end
  end
end
