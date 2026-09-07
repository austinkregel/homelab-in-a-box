defmodule HomelabWeb.Api.V1.SpaceJSONTest do
  use ExUnit.Case, async: true

  alias HomelabWeb.Api.V1.SpaceJSON
  alias Homelab.Tenants.Tenant

  defp tenant(attrs \\ %{}) do
    defaults = %Tenant{
      id: 1,
      name: "Acme",
      slug: "acme",
      status: :active,
      settings: %{"theme" => "dark"},
      inserted_at: ~N[2026-06-01 00:00:00],
      updated_at: ~N[2026-06-02 00:00:00]
    }

    struct(defaults, attrs)
  end

  describe "show/1" do
    test "wraps a single tenant under :data" do
      assert %{data: data} = SpaceJSON.show(%{space: tenant()})
      assert is_map(data)
    end

    test "renders all expected fields" do
      t = tenant()
      %{data: data} = SpaceJSON.show(%{space: t})

      assert data.id == t.id
      assert data.name == t.name
      assert data.slug == t.slug
      assert data.status == t.status
      assert data.settings == t.settings
      assert data.inserted_at == t.inserted_at
      assert data.updated_at == t.updated_at
    end

    test "exposes exactly the documented key set" do
      %{data: data} = SpaceJSON.show(%{space: tenant()})

      assert Map.keys(data) |> Enum.sort() ==
               Enum.sort([
                 :id,
                 :name,
                 :slug,
                 :status,
                 :settings,
                 :inserted_at,
                 :updated_at
               ])
    end

    test "passes settings through as-is, including empty map" do
      %{data: data} = SpaceJSON.show(%{space: tenant(%{settings: %{}})})
      assert data.settings == %{}
    end

    test "passes nil settings through unchanged" do
      %{data: data} = SpaceJSON.show(%{space: tenant(%{settings: nil})})
      assert data.settings == nil
    end

    test "renders the various status enum values" do
      for status <- [:active, :suspended, :archived] do
        %{data: data} = SpaceJSON.show(%{space: tenant(%{status: status})})
        assert data.status == status
      end
    end
  end

  describe "index/1" do
    test "wraps a list of tenants under :data" do
      ts = [tenant(%{id: 1}), tenant(%{id: 2}), tenant(%{id: 3})]
      %{data: list} = SpaceJSON.index(%{spaces: ts})

      assert length(list) == 3
      assert Enum.map(list, & &1.id) == [1, 2, 3]
    end

    test "returns empty list for no tenants" do
      assert SpaceJSON.index(%{spaces: []}) == %{data: []}
    end

    test "shapes each element identically to show/1" do
      t = tenant(%{id: 7})
      %{data: [from_index]} = SpaceJSON.index(%{spaces: [t]})
      %{data: from_show} = SpaceJSON.show(%{space: t})

      assert from_index == from_show
    end
  end
end
