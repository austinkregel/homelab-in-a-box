defmodule Homelab.Catalogs.Curated do
  @moduledoc """
  Manually curated application catalog backed by a JSON file.

  Reads entries from `priv/catalog/curated.json` and caches them
  in `:persistent_term` for fast subsequent access.
  """

  @behaviour Homelab.Behaviours.ApplicationCatalog

  alias Homelab.Catalog.CatalogEntry

  @cache_key {__MODULE__, :entries}

  @impl true
  def driver_id, do: "curated"

  @impl true
  def display_name, do: "Curated"

  @impl true
  def description, do: "Hand-picked collection of self-hostable server applications"

  @impl true
  def browse(_opts \\ []) do
    {:ok, load_entries()}
  end

  @impl true
  def search(query, _opts \\ []) do
    q = String.downcase(query)

    results =
      load_entries()
      |> Enum.filter(fn entry ->
        String.contains?(String.downcase(entry.name), q) or
          String.contains?(String.downcase(entry.description || ""), q) or
          Enum.any?(entry.categories, &String.contains?(String.downcase(&1), q))
      end)

    {:ok, results}
  end

  @impl true
  def app_details(name) do
    case Enum.find(load_entries(), &(&1.name == name)) do
      nil -> {:error, :not_found}
      entry -> {:ok, entry}
    end
  end

  defp load_entries do
    case :persistent_term.get(@cache_key, nil) do
      nil ->
        entries = read_and_parse()
        :persistent_term.put(@cache_key, entries)
        entries

      entries ->
        entries
    end
  end

  defp read_and_parse do
    path = Application.app_dir(:homelab, "priv/catalog/curated.json")

    case File.read(path) do
      {:ok, json} ->
        json
        |> Jason.decode!()
        |> Enum.map(&to_entry/1)

      {:error, reason} ->
        require Logger
        Logger.warning("[Curated] Failed to read catalog: #{inspect(reason)}")
        []
    end
  end

  defp to_entry(item) do
    %CatalogEntry{
      name: item["name"],
      description: item["description"],
      logo_url: item["logo_url"],
      source: "curated",
      full_ref: item["image"],
      project_url: item["project_url"],
      categories: item["categories"] || [],
      required_ports: parse_ports(item["ports"] || []),
      required_volumes: parse_volumes(item["volumes"] || []),
      default_env: item["env"] || %{},
      required_env: item["required_env"] || [],
      official?: true
    }
  end

  defp parse_ports(ports) do
    Enum.map(ports, fn p ->
      %{
        "internal" => p["internal"],
        "external" => p["external"],
        "role" => p["role"] || "other",
        "description" => p["description"] || "",
        "optional" => p["optional"] || false,
        "published" => true
      }
    end)
  end

  defp parse_volumes(volumes) do
    Enum.map(volumes, fn v ->
      %{
        "path" => v["path"],
        "container_path" => v["path"],
        "description" => v["description"] || "",
        "optional" => v["optional"] || false
      }
    end)
  end
end
