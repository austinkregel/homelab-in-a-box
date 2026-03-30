defmodule Homelab.Catalogs.Hotio do
  @moduledoc """
  Application catalog driver for Hotio.

  Hotio maintains curated Docker images focused on media automation
  and management apps (Radarr, Sonarr, Plex, qBittorrent, etc.).
  Images are published to Docker Hub and GHCR under the `hotio/` namespace.
  """

  @behaviour Homelab.Behaviours.ApplicationCatalog

  @impl true
  def driver_id, do: "hotio"

  @impl true
  def display_name, do: "Hotio"

  @impl true
  def description, do: "Curated images for media automation and management"

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
    case fetch_all_repos() do
      {:ok, entries} ->
        :persistent_term.put(cache_key, entries)
        {:ok, entries}

      {:error, _} = err ->
        err
    end
  end

  defp fetch_all_repos do
    base = Application.get_env(:homelab, __MODULE__, [])[:base_url] || "https://hub.docker.com/v2"
    fetch_pages("#{base}/repositories/hotio/?page_size=100", [])
  end

  defp fetch_pages(url, acc) do
    case Req.get(url) do
      {:ok, %{status: 200, body: %{"results" => results} = body}} ->
        entries = Enum.map(results, &parse_repo/1)
        all = acc ++ entries

        case body["next"] do
          nil -> {:ok, all}
          next_url -> fetch_pages(next_url, all)
        end

      {:ok, %{status: status}} ->
        if acc == [], do: {:error, {:http_error, status}}, else: {:ok, acc}

      {:error, reason} ->
        if acc == [], do: {:error, reason}, else: {:ok, acc}
    end
  end

  defp parse_repo(repo) do
    name = repo["name"] || ""

    %Homelab.Catalog.CatalogEntry{
      name: name,
      namespace: "hotio",
      description: repo["description"] || "",
      logo_url: nil,
      version: nil,
      source: "hotio",
      full_ref: "ghcr.io/hotio/#{name}:latest",
      project_url: "https://hotio.dev/containers/#{name}/",
      categories: categorize(name),
      architectures: [],
      stars: repo["star_count"] || 0,
      pulls: repo["pull_count"] || 0,
      official?: false,
      deprecated?: false,
      auth_required?: false
    }
  end

  @media_apps ~w(plex jellyfin emby tautulli overseerr petio)
  @download_apps ~w(qbittorrent deluge nzbget sabnzbd transmission rflood rtorrentvpn)
  @automation_apps ~w(radarr sonarr lidarr readarr prowlarr bazarr whisparr mylar3 recyclarr)
  @indexer_apps ~w(jackett nzbhydra2 prowlarr)
  @utility_apps ~w(autoscan unpackerr rclone restic crop)

  defp categorize(name) do
    cond do
      name in @media_apps -> ["Media"]
      name in @download_apps -> ["Downloads"]
      name in @automation_apps -> ["Automation"]
      name in @indexer_apps -> ["Indexers"]
      name in @utility_apps -> ["Utilities"]
      true -> ["Other"]
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
end
