defmodule HomelabWeb.Api.V1.TenantJSON do
  alias Homelab.Tenants.Tenant

  def index(%{tenants: tenants}) do
    %{data: Enum.map(tenants, &data/1)}
  end

  def show(%{tenant: tenant}) do
    %{data: data(tenant)}
  end

  defp data(%Tenant{} = tenant) do
    %{
      id: tenant.id,
      name: tenant.name,
      slug: tenant.slug,
      status: tenant.status,
      settings: tenant.settings,
      inserted_at: tenant.inserted_at,
      updated_at: tenant.updated_at
    }
  end
end
