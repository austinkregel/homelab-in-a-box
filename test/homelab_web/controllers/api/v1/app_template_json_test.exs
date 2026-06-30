defmodule HomelabWeb.Api.V1.AppTemplateJSONTest do
  use ExUnit.Case, async: true

  alias HomelabWeb.Api.V1.AppTemplateJSON
  alias Homelab.Catalog.AppTemplate

  defp template(attrs \\ %{}) do
    defaults = %AppTemplate{
      id: 1,
      slug: "nextcloud",
      name: "Nextcloud",
      description: "Self-hosted files",
      version: "28.0",
      image: "nextcloud:28",
      exposure_mode: :sso_protected,
      auth_integration: true,
      resource_limits: %{"memory_mb" => 512},
      backup_policy: %{"enabled" => true},
      health_check: %{"path" => "/status.php"},
      depends_on: ["postgres"],
      inserted_at: ~N[2026-06-01 00:00:00],
      updated_at: ~N[2026-06-02 00:00:00]
    }

    struct(defaults, attrs)
  end

  describe "show/1" do
    test "wraps a single template under :data" do
      assert %{data: data} = AppTemplateJSON.show(%{app_template: template()})
      assert is_map(data)
    end

    test "renders all expected fields" do
      t = template()
      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      assert data.id == t.id
      assert data.slug == t.slug
      assert data.name == t.name
      assert data.description == t.description
      assert data.version == t.version
      assert data.image == t.image
      assert data.exposure_mode == t.exposure_mode
      assert data.auth_integration == t.auth_integration
      assert data.resource_limits == t.resource_limits
      assert data.backup_policy == t.backup_policy
      assert data.health_check == t.health_check
      assert data.depends_on == t.depends_on
      assert data.inserted_at == t.inserted_at
      assert data.updated_at == t.updated_at
    end

    test "exposes exactly the documented key set" do
      %{data: data} = AppTemplateJSON.show(%{app_template: template()})

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :slug,
                 :name,
                 :description,
                 :version,
                 :image,
                 :exposure_mode,
                 :auth_integration,
                 :resource_limits,
                 :backup_policy,
                 :health_check,
                 :depends_on,
                 :inserted_at,
                 :updated_at
               ])
    end

    test "does not leak fields outside the documented set (e.g. default_env, ports, volumes)" do
      t =
        template(%{
          default_env: %{"APP_ENV" => "prod"},
          ports: [%{"container" => 8080}],
          volumes: [%{"container_path" => "/data"}],
          source: "marketplace",
          logo_url: "https://example.com/logo.png"
        })

      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      refute Map.has_key?(data, :default_env)
      refute Map.has_key?(data, :ports)
      refute Map.has_key?(data, :volumes)
      refute Map.has_key?(data, :source)
      refute Map.has_key?(data, :logo_url)
    end

    test "preserves nil optional fields" do
      t =
        template(%{
          description: nil,
          version: nil,
          image: nil,
          resource_limits: nil,
          backup_policy: nil,
          health_check: nil
        })

      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      assert data.description == nil
      assert data.version == nil
      assert data.image == nil
      assert data.resource_limits == nil
      assert data.backup_policy == nil
      assert data.health_check == nil
    end

    test "passes empty collection fields through unchanged" do
      t = template(%{depends_on: [], resource_limits: %{}, backup_policy: %{}})
      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      assert data.depends_on == []
      assert data.resource_limits == %{}
      assert data.backup_policy == %{}
    end

    test "renders exposure_mode and auth_integration values" do
      t = template(%{exposure_mode: :public, auth_integration: false})
      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      assert data.exposure_mode == :public
      assert data.auth_integration == false
    end

    test "preserves multi-element depends_on list" do
      t = template(%{depends_on: ["postgres", "redis"]})
      %{data: data} = AppTemplateJSON.show(%{app_template: t})

      assert data.depends_on == ["postgres", "redis"]
    end
  end

  describe "index/1" do
    test "wraps a list of templates under :data" do
      ts = [template(%{id: 1}), template(%{id: 2})]
      %{data: list} = AppTemplateJSON.index(%{app_templates: ts})

      assert length(list) == 2
      assert Enum.map(list, & &1.id) == [1, 2]
    end

    test "returns empty list for no templates" do
      assert AppTemplateJSON.index(%{app_templates: []}) == %{data: []}
    end

    test "shapes each element identically to show/1" do
      t = template(%{id: 9})
      %{data: [from_index]} = AppTemplateJSON.index(%{app_templates: [t]})
      %{data: from_show} = AppTemplateJSON.show(%{app_template: t})

      assert from_index == from_show
    end
  end
end
