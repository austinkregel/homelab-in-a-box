defmodule Homelab.Schemas.TenantChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Tenants.Tenant

  @valid_attrs %{name: "Acme", slug: "acme"}

  defp changeset(attrs), do: Tenant.changeset(%Tenant{}, attrs)

  describe "changeset/2 required fields" do
    test "is valid with name and slug" do
      assert changeset(@valid_attrs).valid?
    end

    test "requires name and slug" do
      cs = changeset(%{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.slug
    end

    test "requires name when slug present" do
      cs = changeset(%{slug: "acme"})
      refute cs.valid?
      assert "can't be blank" in errors_on(cs).name
    end
  end

  describe "changeset/2 slug format and length" do
    test "rejects uppercase slug" do
      cs = changeset(%{@valid_attrs | slug: "Acme"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :slug)
    end

    test "rejects leading hyphen" do
      cs = changeset(%{@valid_attrs | slug: "-acme"})
      refute cs.valid?
    end

    test "rejects trailing hyphen" do
      cs = changeset(%{@valid_attrs | slug: "acme-"})
      refute cs.valid?
    end

    test "rejects single character slug (below min)" do
      cs = changeset(%{@valid_attrs | slug: "a"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :slug)
    end

    test "accepts two-character slug" do
      assert changeset(%{@valid_attrs | slug: "ab"}).valid?
    end

    test "accepts 63-character slug, rejects 64" do
      ok = "a" <> String.duplicate("b", 61) <> "c"
      too_long = "a" <> String.duplicate("b", 62) <> "c"
      assert changeset(%{@valid_attrs | slug: ok}).valid?
      refute changeset(%{@valid_attrs | slug: too_long}).valid?
    end
  end

  describe "changeset/2 status inclusion" do
    test "accepts each valid status" do
      for status <- [:active, :suspended, :archived] do
        assert changeset(Map.put(@valid_attrs, :status, status)).valid?
      end
    end

    test "rejects an invalid status" do
      cs = changeset(Map.put(@valid_attrs, :status, :deleted))
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :status)
    end

    test "defaults status to active" do
      {:ok, tenant} = %Tenant{} |> Tenant.changeset(@valid_attrs) |> Repo.insert()
      assert tenant.status == :active
    end
  end

  describe "unique_constraint on slug" do
    test "rejects a duplicate slug" do
      insert(:tenant, slug: "dup-slug")

      {:error, cs} =
        %Tenant{}
        |> Tenant.changeset(%{name: "Other", slug: "dup-slug"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).slug
    end
  end
end
