defmodule Homelab.Catalogs.OsBasesTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalogs.OsBases

  test "declares its identity" do
    assert OsBases.driver_id() == "os_bases"
    assert OsBases.display_name() == "OS bases"
    assert is_binary(OsBases.description())
  end

  test "browse/1 returns entries, each with a pullable ref and OS category" do
    {:ok, entries} = OsBases.browse()
    assert length(entries) > 5

    assert Enum.all?(entries, fn e ->
             is_binary(e.full_ref) and e.full_ref != "" and
               e.source == "os_bases" and "operating-system" in e.categories
           end)

    names = Enum.map(entries, & &1.name)
    assert Enum.any?(names, &(&1 =~ "Debian"))
    assert Enum.any?(names, &(&1 =~ "Alpine"))
  end

  test "search/2 filters by name and description" do
    {:ok, results} = OsBases.search("ubuntu")
    assert length(results) >= 1
    assert Enum.all?(results, &(String.downcase(&1.name) =~ "ubuntu"))

    {:ok, none} = OsBases.search("definitely-not-an-os")
    assert none == []
  end

  test "app_details/1 finds by exact name" do
    {:ok, entry} = OsBases.app_details("Alpine 3.20")
    assert entry.full_ref == "alpine:3.20"

    assert {:error, :not_found} = OsBases.app_details("nope")
  end
end
