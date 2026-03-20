defmodule Homelab.Catalog do
  @moduledoc """
  Context for managing the app template catalog (marketplace).

  Only curated, safe templates are available. No arbitrary
  user-supplied compose files.
  """

  alias Homelab.Repo
  alias Homelab.Catalog.AppTemplate

  def list_app_templates do
    Repo.all(AppTemplate)
  end

  def get_app_template(id) do
    case Repo.get(AppTemplate, id) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  def get_app_template!(id) do
    Repo.get!(AppTemplate, id)
  end

  def get_app_template_by_slug(slug) do
    case Repo.get_by(AppTemplate, slug: slug) do
      nil -> {:error, :not_found}
      template -> {:ok, template}
    end
  end

  def create_app_template(attrs) do
    %AppTemplate{}
    |> AppTemplate.changeset(attrs)
    |> Repo.insert()
  end

  def update_app_template(%AppTemplate{} = template, attrs) do
    template
    |> AppTemplate.changeset(attrs)
    |> Repo.update()
  end

  def delete_app_template(%AppTemplate{} = template) do
    Repo.delete(template)
  end

  def change_app_template(%AppTemplate{} = template, attrs \\ %{}) do
    AppTemplate.changeset(template, attrs)
  end
end
