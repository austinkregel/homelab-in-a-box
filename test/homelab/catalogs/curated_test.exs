defmodule Homelab.Catalogs.CuratedTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalogs.Curated

  setup do
    :persistent_term.erase({Curated, :entries})
    :ok
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert Curated.driver_id() == "curated"
    end

    test "returns display_name" do
      assert Curated.display_name() == "Curated"
    end

    test "returns description" do
      assert is_binary(Curated.description())
    end
  end

  describe "browse/1" do
    test "returns a list of catalog entries" do
      assert {:ok, entries} = Curated.browse()
      assert is_list(entries)
      assert length(entries) > 0
    end

    test "entries have required fields" do
      {:ok, [entry | _]} = Curated.browse()
      assert entry.name != nil
      assert entry.source == "curated"
    end
  end

  describe "search/2" do
    test "finds entries matching query" do
      {:ok, all} = Curated.browse()
      first_name = hd(all).name

      {:ok, results} = Curated.search(first_name)
      assert length(results) > 0

      assert Enum.any?(results, fn e ->
               String.contains?(String.downcase(e.name), String.downcase(first_name))
             end)
    end

    test "returns empty list for no matches" do
      {:ok, results} = Curated.search("zzz_nonexistent_app_zzz")
      assert results == []
    end
  end

  describe "app_details/1" do
    test "returns entry by name" do
      {:ok, [entry | _]} = Curated.browse()
      assert {:ok, detail} = Curated.app_details(entry.name)
      assert detail.name == entry.name
    end

    test "returns error for unknown app" do
      assert {:error, :not_found} = Curated.app_details("nonexistent_app")
    end
  end
end
