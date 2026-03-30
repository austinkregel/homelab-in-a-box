defmodule Homelab.Catalogs.AwesomeSelfhosted do
  @moduledoc """
  Application catalog driver for the Awesome-Selfhosted list.

  Awesome-Selfhosted is a community-curated list of self-hostable software
  with 600+ entries across 50+ categories. The machine-readable data lives
  at github.com/awesome-selfhosted/awesome-selfhosted-data.

  Not every entry has a Docker image — entries without one are still shown
  for discovery but marked with a nil `full_ref`. The catalog syncs by
  fetching the Git tree and downloading YAML files in batches.
  """

  @behaviour Homelab.Behaviours.ApplicationCatalog

  @repo "awesome-selfhosted/awesome-selfhosted-data"
  @branch "master"

  @impl true
  def driver_id, do: "awesome_selfhosted"

  @impl true
  def display_name, do: "Awesome-Selfhosted"

  @impl true
  def description, do: "Community-curated directory of 600+ self-hostable applications"

  @impl true
  def browse(opts \\ []) do
    case get_catalog(opts) do
      {:ok, entries} -> {:ok, entries}
      {:error, _} = err -> err
    end
  end

  @impl true
  def search(query, opts \\ []) do
    case browse(opts) do
      {:ok, entries} ->
        query_lower = String.downcase(query)
        {:ok, Enum.filter(entries, &matches?(&1, query_lower))}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def app_details(name) do
    case browse() do
      {:ok, entries} ->
        case Enum.find(entries, fn e -> e.name == name end) do
          nil -> {:error, :not_found}
          entry -> {:ok, entry}
        end

      {:error, _} = err ->
        err
    end
  end

  defp get_catalog(_opts) do
    cache_key = {__MODULE__, :catalog}

    case :persistent_term.get(cache_key, nil) do
      nil -> fetch_and_cache_catalog(cache_key)
      entries -> {:ok, entries}
    end
  end

  defp fetch_and_cache_catalog(cache_key) do
    require Logger

    with {:ok, file_list} <- fetch_file_list(),
         {:ok, entries} <- fetch_entries(file_list) do
      :persistent_term.put(cache_key, entries)
      Logger.info("[AwesomeSelfhosted] Cached #{length(entries)} entries")
      {:ok, entries}
    end
  end

  defp fetch_file_list do
    base = Application.get_env(:homelab, __MODULE__, [])[:github_api_url] || "https://api.github.com"
    url = "#{base}/repos/#{@repo}/git/trees/#{@branch}?recursive=1"

    case Req.get(url, headers: github_headers()) do
      {:ok, %{status: 200, body: %{"tree" => tree}}} ->
        yml_files =
          tree
          |> Enum.filter(fn node ->
            node["type"] == "blob" and String.starts_with?(node["path"], "software/") and
              String.ends_with?(node["path"], ".yml")
          end)
          |> Enum.map(fn node -> node["path"] end)

        {:ok, yml_files}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_entries(file_paths) do
    entries =
      file_paths
      |> Task.async_stream(
        fn path -> fetch_and_parse_entry(path) end,
        max_concurrency: 10,
        timeout: :infinity
      )
      |> Enum.flat_map(fn
        {:ok, {:ok, entry}} -> [entry]
        _ -> []
      end)

    {:ok, entries}
  end

  defp fetch_and_parse_entry(path) do
    raw_base = Application.get_env(:homelab, __MODULE__, [])[:raw_url] || "https://raw.githubusercontent.com"
    url = "#{raw_base}/#{@repo}/#{@branch}/#{path}"

    case Req.get(url, headers: github_headers()) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        parse_yaml(body)

      _ ->
        {:error, :fetch_failed}
    end
  end

  defp parse_yaml(yaml_string) do
    case YamlElixir.read_from_string(yaml_string) do
      {:ok, data} when is_map(data) ->
        name = data["name"]

        if name && name != "" do
          tags = List.wrap(data["tags"])
          platforms = List.wrap(data["platforms"])

          docker_image = infer_docker_image(name, data)

          {:ok,
           %Homelab.Catalog.CatalogEntry{
             name: name,
             namespace: nil,
             description: data["description"],
             logo_url: nil,
             version: get_in(data, ["current_release", "tag"]),
             source: "awesome_selfhosted",
             full_ref: docker_image,
             project_url: data["website_url"] || data["source_code_url"],
             categories: tags,
             architectures: platforms,
             stars: data["stargazers_count"] || 0,
             pulls: 0,
             official?: false,
             deprecated?: data["archived"] == true,
             auth_required?: false
           }}
        else
          {:error, :no_name}
        end

      _ ->
        {:error, :parse_failed}
    end
  end

  defp infer_docker_image(name, data) do
    source_url = data["source_code_url"] || ""

    cond do
      String.contains?(source_url, "github.com") ->
        case Regex.run(~r|github\.com/([^/]+/[^/]+)|, source_url) do
          [_, owner_repo] -> "ghcr.io/#{String.downcase(owner_repo)}:latest"
          _ -> nil
        end

      String.contains?(source_url, "gitlab.com") ->
        slug = name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")
        "registry.gitlab.com/#{slug}:latest"

      true ->
        nil
    end
  end

  defp matches?(entry, query_lower) do
    name_match = entry.name && String.contains?(String.downcase(entry.name), query_lower)

    desc_match =
      entry.description && String.contains?(String.downcase(entry.description), query_lower)

    cats_match =
      Enum.any?(entry.categories || [], fn cat ->
        String.contains?(String.downcase(cat), query_lower)
      end)

    name_match || desc_match || cats_match
  end

  defp github_headers do
    case System.get_env("GITHUB_TOKEN") do
      nil -> [{"user-agent", "homelab-in-a-box"}]
      token -> [{"user-agent", "homelab-in-a-box"}, {"authorization", "Bearer #{token}"}]
    end
  end
end
