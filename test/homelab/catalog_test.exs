defmodule Homelab.CatalogTest do
  use Homelab.DataCase, async: true

  alias Homelab.Catalog
  alias Homelab.Catalog.AppTemplate
  import Homelab.Factory

  describe "list_app_templates/0" do
    test "returns all templates" do
      insert(:app_template)
      insert(:app_template)

      assert length(Catalog.list_app_templates()) == 2
    end

    test "returns empty list when no templates exist" do
      assert Catalog.list_app_templates() == []
    end
  end

  describe "get_app_template/1" do
    test "returns template by id" do
      template = insert(:app_template)
      assert {:ok, found} = Catalog.get_app_template(template.id)
      assert found.id == template.id
    end

    test "returns error when template not found" do
      assert {:error, :not_found} = Catalog.get_app_template(999)
    end
  end

  describe "get_app_template_by_slug/1" do
    test "returns template by slug" do
      template = insert(:app_template, slug: "nextcloud")
      assert {:ok, found} = Catalog.get_app_template_by_slug("nextcloud")
      assert found.id == template.id
    end

    test "returns error when slug not found" do
      assert {:error, :not_found} = Catalog.get_app_template_by_slug("nonexistent")
    end
  end

  describe "create_app_template/1" do
    test "creates a template with valid attrs" do
      attrs = %{
        slug: "nextcloud",
        name: "Nextcloud",
        version: "28.0",
        image: "nextcloud:28.0",
        description: "Self-hosted file sync"
      }

      assert {:ok, %AppTemplate{} = template} = Catalog.create_app_template(attrs)
      assert template.slug == "nextcloud"
      assert template.name == "Nextcloud"
      assert template.image == "nextcloud:28.0"
      assert template.exposure_mode == :sso_protected
      assert template.auth_integration == true
    end

    test "returns error with invalid slug" do
      attrs = %{slug: "A", name: "Test", version: "1.0", image: "test:1"}
      assert {:error, changeset} = Catalog.create_app_template(attrs)
      assert errors_on(changeset).slug != []
    end

    test "returns error when slug is taken" do
      insert(:app_template, slug: "taken")
      attrs = %{slug: "taken", name: "Another", version: "1.0", image: "test:1"}
      assert {:error, changeset} = Catalog.create_app_template(attrs)
      assert errors_on(changeset).slug != []
    end

    test "returns error when required fields are missing" do
      assert {:error, changeset} = Catalog.create_app_template(%{})
      assert errors_on(changeset).slug != []
      assert errors_on(changeset).name != []
      assert errors_on(changeset).version != []
      assert errors_on(changeset).image != []
    end

    test "creates template with resource limits and backup policy" do
      attrs = %{
        slug: "jellyfin",
        name: "Jellyfin",
        version: "10.8",
        image: "jellyfin/jellyfin:10.8",
        resource_limits: %{"memory_mb" => 1024, "cpu_shares" => 2048},
        backup_policy: %{
          "enabled" => true,
          "schedule" => "0 3 * * *",
          "paths" => ["/config", "/media"]
        }
      }

      assert {:ok, template} = Catalog.create_app_template(attrs)
      assert template.resource_limits == %{"memory_mb" => 1024, "cpu_shares" => 2048}
      assert template.backup_policy["enabled"] == true
    end
  end

  describe "update_app_template/2" do
    test "updates a template" do
      template = insert(:app_template)
      assert {:ok, updated} = Catalog.update_app_template(template, %{version: "2.0.0"})
      assert updated.version == "2.0.0"
    end

    test "can change exposure mode" do
      template = insert(:app_template)
      assert {:ok, updated} = Catalog.update_app_template(template, %{exposure_mode: :public})
      assert updated.exposure_mode == :public
    end
  end

  describe "delete_app_template/1" do
    test "deletes a template" do
      template = insert(:app_template)
      assert {:ok, _} = Catalog.delete_app_template(template)
      assert {:error, :not_found} = Catalog.get_app_template(template.id)
    end
  end
end
