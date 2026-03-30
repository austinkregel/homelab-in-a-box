defmodule Homelab.Catalog.MetadataEnricherTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.MetadataEnricher
  alias Homelab.Catalog.CatalogEntry

  describe "enrich/2" do
    test "returns enriched entry (cached on second call)" do
      entry = %CatalogEntry{
        name: "test-enrich-app",
        source: "test",
        full_ref: nil,
        project_url: nil,
        required_ports: [],
        required_volumes: [],
        default_env: %{},
        required_env: [],
        categories: []
      }

      :persistent_term.erase({:enrichment, "test", "test-enrich-app"})

      {:ok, enriched} = MetadataEnricher.enrich(entry)
      assert enriched.name == "test-enrich-app"

      {:ok, cached} = MetadataEnricher.enrich(entry)
      assert cached.name == enriched.name
    end

    test "preserves existing entry data" do
      entry = %CatalogEntry{
        name: "preserve-test",
        source: "test",
        full_ref: nil,
        project_url: nil,
        required_ports: [%{"internal" => "80", "external" => "80"}],
        required_volumes: [%{"path" => "/data"}],
        default_env: %{"EXISTING" => "value"},
        required_env: ["REQUIRED_VAR"],
        categories: []
      }

      :persistent_term.erase({:enrichment, "test", "preserve-test"})

      {:ok, enriched} = MetadataEnricher.enrich(entry)
      assert enriched.default_env["EXISTING"] == "value"
      assert "REQUIRED_VAR" in enriched.required_env
      assert length(enriched.required_ports) >= 1
    end
  end
end
