defmodule Homelab.Catalog.DedupTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.CatalogEntry
  alias Homelab.Catalog.Dedup

  defp entry(attrs), do: struct(CatalogEntry, attrs)

  describe "normalize_name/1" do
    test "collapses case, spaces, underscores and hyphens to one grouping key" do
      key = Dedup.normalize_name(entry(name: "Home Assistant"))

      for variant <- ["home-assistant", "home_assistant", "HOME  assistant", "Home-Assistant"] do
        assert Dedup.normalize_name(entry(name: variant)) == key
      end
    end

    test "treats a nil name as the empty key without crashing" do
      assert Dedup.normalize_name(entry(name: nil)) == ""
    end
  end

  describe "deduplicate_entries/1" do
    test "passes a single entry through untouched" do
      only = entry(name: "grafana", source: :dockerhub)
      assert Dedup.deduplicate_entries([only]) == [only]
    end

    test "groups differently-formatted names for the same app into one entry" do
      entries = [
        entry(name: "Home Assistant", source: :dockerhub),
        entry(name: "home-assistant", source: :ghcr)
      ]

      assert [merged] = Dedup.deduplicate_entries(entries)
      assert merged.name in ["Home Assistant", "home-assistant"]
    end

    # The regression this module exists to prevent: the deploy wizard's old private
    # copy scored richness WITHOUT the setup_url signal, so for two otherwise-equal
    # entries it could pick a different primary than the catalog browser did.
    test "setup_url breaks a richness tie, so both surfaces pick the same primary" do
      with_setup =
        entry(name: "immich", source: :curated, setup_url: "https://immich.app/docs")

      without_setup = entry(name: "Immich", source: :dockerhub, setup_url: nil)

      assert [primary] = Dedup.deduplicate_entries([without_setup, with_setup])
      assert primary.source == :curated
      assert primary.setup_url == "https://immich.app/docs"
    end

    test "keeps the richest entry as primary and folds the rest into alt_sources" do
      rich =
        entry(
          name: "nextcloud",
          source: :curated,
          full_ref: "curated/nextcloud",
          logo_url: "https://logo",
          description: "files",
          required_ports: [443],
          categories: ["storage"]
        )

      sparse =
        entry(
          name: "nextcloud",
          source: :dockerhub,
          full_ref: "library/nextcloud",
          categories: ["cloud"]
        )

      assert [primary] = Dedup.deduplicate_entries([sparse, rich])
      assert primary.source == :curated
      assert primary.alt_sources == [%{source: :dockerhub, full_ref: "library/nextcloud"}]
      assert Enum.sort(primary.categories) == ["cloud", "storage"]
    end

    test "deduplicates alt_sources by source" do
      primary = entry(name: "app", source: :curated, logo_url: "l", full_ref: "curated/app")
      dup_a = entry(name: "app", source: :dockerhub, full_ref: "library/app")
      dup_b = entry(name: "app", source: :dockerhub, full_ref: "library/app:2")

      assert [merged] = Dedup.deduplicate_entries([primary, dup_a, dup_b])
      assert merged.source == :curated
      assert length(merged.alt_sources) == 1
    end
  end
end
