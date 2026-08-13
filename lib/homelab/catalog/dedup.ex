defmodule Homelab.Catalog.Dedup do
  @moduledoc """
  Collapses catalog entries that describe the same application but arrive from
  different sources (registries, curated catalogs) into one entry.

  Entries are grouped by a normalized name; within each group the richest entry
  wins and the others are folded in as `:alt_sources`, with categories merged
  across the whole group.

  This lived as two drifted private copies — the catalog browser and the deploy
  wizard — where the wizard's copy scored entries without the `setup_url` signal
  and skipped the alt-source/category merge entirely, so the two surfaces could
  pick a different "primary" for the same app. Both now call this one function.
  """

  alias Homelab.Catalog.CatalogEntry

  @doc """
  Group entries by normalized name and merge each group into a single entry.
  """
  @spec deduplicate_entries([CatalogEntry.t()]) :: [CatalogEntry.t()]
  def deduplicate_entries(entries) do
    entries
    |> Enum.group_by(&normalize_name/1)
    |> Enum.map(fn {_key, group} -> merge_duplicates(group) end)
  end

  @doc """
  Normalized grouping key for an entry: lowercased name with spaces, underscores
  and hyphens stripped, so "Home Assistant", "home-assistant" and "home_assistant"
  collapse together.
  """
  @spec normalize_name(CatalogEntry.t()) :: String.t()
  def normalize_name(entry) do
    (entry.name || "")
    |> String.downcase()
    |> String.replace(~r/[\s_\-]+/, "")
  end

  @spec merge_duplicates([CatalogEntry.t()]) :: CatalogEntry.t()
  defp merge_duplicates([single]), do: single

  defp merge_duplicates(group) do
    primary = Enum.max_by(group, &richness_score/1)

    alt_sources =
      group
      |> Enum.reject(&(&1.source == primary.source))
      |> Enum.map(fn e -> %{source: e.source, full_ref: e.full_ref} end)
      |> Enum.uniq_by(& &1.source)

    merged_categories =
      group
      |> Enum.flat_map(& &1.categories)
      |> Enum.uniq()

    primary
    |> Map.put(:alt_sources, alt_sources)
    |> Map.put(:categories, merged_categories)
  end

  # How much usable metadata an entry carries; the highest-scoring entry in a
  # group becomes the primary. logo_url is weighted double as the strongest
  # signal that an entry is curated rather than a bare registry hit.
  @spec richness_score(CatalogEntry.t()) :: non_neg_integer()
  defp richness_score(entry) do
    length(entry.required_ports) + length(entry.required_volumes) +
      map_size(entry.default_env) +
      if(entry.description && entry.description != "", do: 1, else: 0) +
      if(entry.logo_url, do: 2, else: 0) +
      if(entry.setup_url, do: 1, else: 0)
  end
end
