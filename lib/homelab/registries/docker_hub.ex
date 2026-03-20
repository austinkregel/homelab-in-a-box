defmodule Homelab.Registries.DockerHub do
  @moduledoc "Container registry driver for Docker Hub."

  @behaviour Homelab.Behaviours.ContainerRegistry

  @impl true
  def driver_id, do: "dockerhub"

  @impl true
  def display_name, do: "Docker Hub"

  @impl true
  def description, do: "The default public container registry"

  @impl true
  def capabilities, do: [:search, :list_tags]

  @impl true
  def search(query, opts \\ []) do
    page_size = Keyword.get(opts, :page_size, 25)

    url =
      "https://hub.docker.com/v2/search/repositories/?query=#{URI.encode_www_form(query)}&page_size=#{page_size}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        entries = parse_search_results(body)
        {:ok, entries}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def list_tags(image, opts \\ []) do
    # image is "namespace/repo" or just "repo" (for library)
    page_size = Keyword.get(opts, :page_size, 50)
    url = "https://hub.docker.com/v2/repositories/#{image}/tags/?page_size=#{page_size}"

    case Req.get(url) do
      {:ok, %{status: 200, body: body}} ->
        tags = parse_tag_results(body)
        {:ok, tags}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def full_image_ref(name, tag) do
    # name can be "namespace/repo" or "repo"
    "#{name}:#{tag}"
  end

  # --- Private ---

  defp parse_search_results(%{"results" => results}) do
    Enum.map(results, fn r ->
      repo_name = r["repo_name"] || ""

      %Homelab.Catalog.CatalogEntry{
        name: repo_name,
        namespace: r["repo_owner"],
        description: r["short_description"],
        logo_url: nil,
        version: nil,
        source: "dockerhub",
        full_ref: "#{repo_name}:latest",
        project_url: nil,
        categories: [],
        architectures: [],
        stars: r["star_count"] || 0,
        pulls: r["pull_count"] || 0,
        official?: r["is_official"] == true,
        deprecated?: false,
        auth_required?: false
      }
    end)
  end

  defp parse_search_results(_), do: []

  defp parse_tag_results(%{"results" => results}) do
    Enum.map(results, fn r ->
      architectures =
        (r["images"] || [])
        |> Enum.map(fn img -> img["architecture"] end)
        |> Enum.reject(&(&1 == "unknown"))

      %Homelab.Catalog.TagInfo{
        tag: r["name"],
        digest: r["digest"],
        last_updated: r["last_updated"],
        size_bytes: r["full_size"],
        architectures: architectures
      }
    end)
  end

  defp parse_tag_results(_), do: []
end
