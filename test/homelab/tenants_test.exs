defmodule Homelab.TenantsTest do
  use Homelab.DataCase, async: true

  alias Homelab.Tenants
  alias Homelab.Tenants.Tenant
  import Homelab.Factory

  describe "list_tenants/0" do
    test "returns all tenants" do
      insert(:tenant)
      insert(:tenant)

      assert length(Tenants.list_tenants()) == 2
    end

    test "returns empty list when no tenants exist" do
      assert Tenants.list_tenants() == []
    end
  end

  describe "list_active_tenants/0" do
    test "returns only active tenants" do
      insert(:tenant, status: :active)
      insert(:tenant, status: :suspended)
      insert(:tenant, status: :archived)

      active = Tenants.list_active_tenants()
      assert length(active) == 1
      assert hd(active).status == :active
    end
  end

  describe "get_tenant/1" do
    test "returns tenant by id" do
      tenant = insert(:tenant)
      assert {:ok, found} = Tenants.get_tenant(tenant.id)
      assert found.id == tenant.id
    end

    test "returns error when tenant not found" do
      assert {:error, :not_found} = Tenants.get_tenant(999)
    end
  end

  describe "get_tenant_by_slug/1" do
    test "returns tenant by slug" do
      tenant = insert(:tenant, slug: "my-friends")
      assert {:ok, found} = Tenants.get_tenant_by_slug("my-friends")
      assert found.id == tenant.id
    end

    test "returns error when slug not found" do
      assert {:error, :not_found} = Tenants.get_tenant_by_slug("nonexistent")
    end
  end

  describe "create_tenant/1" do
    test "creates a tenant with valid attrs" do
      attrs = %{name: "My Friends", slug: "my-friends"}
      assert {:ok, %Tenant{} = tenant} = Tenants.create_tenant(attrs)
      assert tenant.name == "My Friends"
      assert tenant.slug == "my-friends"
      assert tenant.status == :active
    end

    test "returns error with invalid slug format" do
      attrs = %{name: "Test", slug: "INVALID SLUG!"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end

    test "returns error when slug is taken" do
      insert(:tenant, slug: "taken")
      attrs = %{name: "Another", slug: "taken"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end

    test "returns error when name is missing" do
      attrs = %{slug: "valid-slug"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).name != []
    end

    test "returns error when slug is too short" do
      attrs = %{name: "Test", slug: "a"}
      assert {:error, changeset} = Tenants.create_tenant(attrs)
      assert errors_on(changeset).slug != []
    end
  end

  describe "update_tenant/2" do
    test "updates a tenant" do
      tenant = insert(:tenant)
      assert {:ok, updated} = Tenants.update_tenant(tenant, %{name: "New Name"})
      assert updated.name == "New Name"
    end

    test "can suspend a tenant" do
      tenant = insert(:tenant)
      assert {:ok, updated} = Tenants.update_tenant(tenant, %{status: :suspended})
      assert updated.status == :suspended
    end
  end

  describe "delete_tenant/1" do
    test "deletes a tenant" do
      tenant = insert(:tenant)
      assert {:ok, _} = Tenants.delete_tenant(tenant)
      assert {:error, :not_found} = Tenants.get_tenant(tenant.id)
    end
  end
end
