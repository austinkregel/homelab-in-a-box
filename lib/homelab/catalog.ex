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

  @doc """
  Resolve a template's `suggested_additional_domains` against the primary domain an
  operator is deploying under, ready to hand to `Deployment.additional_domains`.

  The suggestion is stored with a BLANK host because the apex is operator-specific -- it
  is the parent of the primary domain (`matrix.example.com` -> `example.com`), which the
  template cannot know. This fills each blank host from that parent and drops any row it
  cannot resolve (a primary domain with no parent, e.g. a bare apex, or an unset domain),
  so a caller can merge the result straight into deployment attrs without re-checking.

  A row that already carries an explicit host is left as the operator set it.
  """
  def resolve_suggested_domains(%AppTemplate{} = template, primary_domain) do
    resolve_suggested_domains(template.suggested_additional_domains, primary_domain)
  end

  def resolve_suggested_domains(suggested, primary_domain) when is_list(suggested) do
    apex = parent_domain(primary_domain)

    suggested
    |> Enum.map(&fill_blank_host(&1, apex))
    |> Enum.reject(&blank_host?/1)
  end

  def resolve_suggested_domains(_suggested, _primary_domain), do: []

  @doc """
  The parent of a hostname -- the host one label up. `matrix.example.com` -> `example.com`.

  Returns nil when there is no usable parent: a bare apex like `example.com` yields `com`,
  which is not a routable delegation target, so anything without at least two labels of
  parent (i.e. the parent must itself contain a dot) resolves to nil. This is the same
  FQDN bar `Deployment.valid_host?/1` enforces, checked here so an unresolvable suggestion
  is dropped rather than saved and rejected.
  """
  def parent_domain(domain) when is_binary(domain) do
    case String.split(String.trim(domain), ".", parts: 2) do
      [_label, parent] -> if String.contains?(parent, "."), do: parent, else: nil
      _ -> nil
    end
  end

  def parent_domain(_domain), do: nil

  defp fill_blank_host(entry, apex) when is_map(entry) do
    if blank_host?(entry) and is_binary(apex), do: Map.put(entry, "host", apex), else: entry
  end

  defp blank_host?(entry) when is_map(entry) do
    host = entry["host"]
    not is_binary(host) or String.trim(host) == ""
  end
end
