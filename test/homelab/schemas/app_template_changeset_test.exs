defmodule Homelab.Schemas.AppTemplateChangesetTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Catalog.AppTemplate

  @valid_attrs %{
    slug: "my-app",
    name: "My App",
    version: "1.2.3",
    image: "myapp:latest"
  }

  defp changeset(attrs), do: AppTemplate.changeset(%AppTemplate{}, attrs)

  describe "changeset/2 required fields" do
    test "is valid with the minimal required attrs" do
      assert changeset(@valid_attrs).valid?
    end

    test "requires slug, name, version, and image" do
      cs = changeset(%{})
      refute cs.valid?
      errors = errors_on(cs)
      assert "can't be blank" in errors.slug
      assert "can't be blank" in errors.name
      assert "can't be blank" in errors.version
      assert "can't be blank" in errors.image
    end

    test "each required field individually triggers blank error when absent" do
      for field <- [:slug, :name, :version, :image] do
        attrs = Map.delete(@valid_attrs, field)
        cs = changeset(attrs)
        refute cs.valid?, "expected invalid when #{field} missing"
        assert "can't be blank" in Map.get(errors_on(cs), field)
      end
    end
  end

  describe "changeset/2 slug format" do
    test "accepts lowercase alphanumeric with hyphens" do
      assert changeset(%{@valid_attrs | slug: "app-123-x"}).valid?
    end

    test "rejects uppercase letters" do
      cs = changeset(%{@valid_attrs | slug: "MyApp"})
      refute cs.valid?
      assert "must be lowercase alphanumeric with hyphens" in errors_on(cs).slug
    end

    test "rejects leading hyphen" do
      cs = changeset(%{@valid_attrs | slug: "-app"})
      refute cs.valid?
      assert "must be lowercase alphanumeric with hyphens" in errors_on(cs).slug
    end

    test "rejects trailing hyphen" do
      cs = changeset(%{@valid_attrs | slug: "app-"})
      refute cs.valid?
      assert "must be lowercase alphanumeric with hyphens" in errors_on(cs).slug
    end

    test "rejects underscores and other special characters" do
      cs = changeset(%{@valid_attrs | slug: "my_app"})
      refute cs.valid?
      assert "must be lowercase alphanumeric with hyphens" in errors_on(cs).slug
    end

    test "accepts two-character all-alphanumeric slug" do
      assert changeset(%{@valid_attrs | slug: "ab"}).valid?
    end
  end

  describe "changeset/2 length boundaries" do
    test "rejects a one-character slug (below min length)" do
      cs = changeset(%{@valid_attrs | slug: "a"})
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :slug)
    end

    test "accepts a slug at the 63 character maximum" do
      slug = "a" <> String.duplicate("b", 61) <> "c"
      assert String.length(slug) == 63
      assert changeset(%{@valid_attrs | slug: slug}).valid?
    end

    test "rejects a slug over 63 characters" do
      slug = "a" <> String.duplicate("b", 63) <> "c"
      assert String.length(slug) == 65
      cs = changeset(%{@valid_attrs | slug: slug})
      refute cs.valid?
      assert "should be at most 63 character(s)" in errors_on(cs).slug
    end

    test "accepts a name at the 255 character maximum" do
      assert changeset(%{@valid_attrs | name: String.duplicate("n", 255)}).valid?
    end

    test "rejects a name over 255 characters" do
      cs = changeset(%{@valid_attrs | name: String.duplicate("n", 256)})
      refute cs.valid?
      assert "should be at most 255 character(s)" in errors_on(cs).name
    end
  end

  describe "changeset/2 enums and defaults" do
    test "casts a valid exposure_mode" do
      cs = changeset(Map.put(@valid_attrs, :exposure_mode, :public))
      assert cs.valid?
      assert get_change(cs, :exposure_mode) == :public
    end

    test "rejects an invalid exposure_mode" do
      cs = changeset(Map.put(@valid_attrs, :exposure_mode, :nonsense))
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :exposure_mode)
    end

    test "casts a valid auth_mode value" do
      cs = changeset(Map.put(@valid_attrs, :auth_mode, :oidc_standard))
      assert cs.valid?
      assert get_change(cs, :auth_mode) == :oidc_standard
    end

    test "rejects an invalid auth_mode" do
      cs = changeset(Map.put(@valid_attrs, :auth_mode, :bogus))
      refute cs.valid?
      assert Map.has_key?(errors_on(cs), :auth_mode)
    end

    test "casts optional array and map fields" do
      attrs =
        @valid_attrs
        |> Map.put(:required_env, ["FOO", "BAR"])
        |> Map.put(:default_env, %{"A" => "1"})
        |> Map.put(:depends_on, ["postgres"])

      cs = changeset(attrs)
      assert cs.valid?
      assert get_change(cs, :required_env) == ["FOO", "BAR"]
      assert get_change(cs, :default_env) == %{"A" => "1"}
      assert get_change(cs, :depends_on) == ["postgres"]
    end
  end

  describe "unique_constraint on slug (via Repo)" do
    test "rejects a duplicate slug on insert" do
      insert(:app_template, slug: "taken-slug")

      {:error, cs} =
        %AppTemplate{}
        |> AppTemplate.changeset(%{@valid_attrs | slug: "taken-slug"})
        |> Repo.insert()

      assert "has already been taken" in errors_on(cs).slug
    end

    test "allows distinct slugs to be inserted" do
      assert {:ok, _} =
               %AppTemplate{}
               |> AppTemplate.changeset(%{@valid_attrs | slug: "first-app"})
               |> Repo.insert()

      assert {:ok, _} =
               %AppTemplate{}
               |> AppTemplate.changeset(%{@valid_attrs | slug: "second-app"})
               |> Repo.insert()
    end
  end
end
