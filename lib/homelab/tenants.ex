defmodule Homelab.Tenants do
  @moduledoc """
  Context for managing tenants (Spaces).

  Each tenant represents a friend/family group with their own
  isolated namespace, storage, and deployments.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Tenants.Tenant

  def list_tenants do
    Repo.all(Tenant)
  end

  def list_active_tenants do
    Tenant
    |> where(status: :active)
    |> Repo.all()
  end

  def get_tenant(id) do
    case Repo.get(Tenant, id) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  def get_tenant!(id) do
    Repo.get!(Tenant, id)
  end

  def get_tenant_by_slug(slug) do
    case Repo.get_by(Tenant, slug: slug) do
      nil -> {:error, :not_found}
      tenant -> {:ok, tenant}
    end
  end

  def create_tenant(attrs) do
    %Tenant{}
    |> Tenant.changeset(attrs)
    |> Repo.insert()
  end

  def update_tenant(%Tenant{} = tenant, attrs) do
    tenant
    |> Tenant.changeset(attrs)
    |> Repo.update()
  end

  def delete_tenant(%Tenant{} = tenant) do
    Repo.delete(tenant)
  end

  def change_tenant(%Tenant{} = tenant, attrs \\ %{}) do
    Tenant.changeset(tenant, attrs)
  end
end
