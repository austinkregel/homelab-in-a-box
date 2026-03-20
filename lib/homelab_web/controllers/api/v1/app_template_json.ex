defmodule HomelabWeb.Api.V1.AppTemplateJSON do
  alias Homelab.Catalog.AppTemplate

  def index(%{app_templates: templates}) do
    %{data: Enum.map(templates, &data/1)}
  end

  def show(%{app_template: template}) do
    %{data: data(template)}
  end

  defp data(%AppTemplate{} = t) do
    %{
      id: t.id,
      slug: t.slug,
      name: t.name,
      description: t.description,
      version: t.version,
      image: t.image,
      exposure_mode: t.exposure_mode,
      auth_integration: t.auth_integration,
      resource_limits: t.resource_limits,
      backup_policy: t.backup_policy,
      health_check: t.health_check,
      depends_on: t.depends_on,
      inserted_at: t.inserted_at,
      updated_at: t.updated_at
    }
  end
end
