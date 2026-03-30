defmodule Homelab.Catalogs.LinuxServer do
  @moduledoc """
  Application catalog driver for LinuxServer.io.

  LinuxServer.io is a community that maintains high-quality Docker images
  for popular self-hosted applications. Their images are published to
  Docker Hub under the `linuxserver/` namespace and to `lscr.io`.
  """

  @behaviour Homelab.Behaviours.ApplicationCatalog

  @impl true
  def driver_id, do: "linuxserver"

  @impl true
  def display_name, do: "LinuxServer.io"

  @impl true
  def description, do: "Community-maintained images for popular self-hosted apps"

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
    base = Application.get_env(:homelab, __MODULE__, [])[:base_url] || "https://api.linuxserver.io"
    case Req.get("#{base}/api/v1/images?include_config=true") do
      {:ok, %{status: 200, body: body}} ->
        entries = parse_response(body)
        :persistent_term.put(cache_key, entries)
        {:ok, entries}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_response(%{"status" => "OK", "data" => %{"repositories" => repos}}) do
    images = repos["linuxserver"] || []

    Enum.map(images, fn img ->
      categories =
        img
        |> Map.get("category", "")
        |> String.split(",", trim: true)
        |> Enum.map(&String.trim/1)

      architectures =
        (img["architectures"] || [])
        |> Enum.map(fn %{"arch" => arch} -> arch end)

      config = img["config"] || %{}

      volumes =
        (config["volumes"] || [])
        |> Enum.map(fn vol ->
          %{
            "path" => vol["path"],
            "description" => vol["desc"],
            "optional" => vol["optional"] == true
          }
        end)

      ports =
        (config["ports"] || [])
        |> Enum.map(fn port ->
          %{
            "internal" => port["internal"],
            "external" => port["external"],
            "description" => port["desc"],
            "optional" => port["optional"] == true
          }
        end)

      %Homelab.Catalog.CatalogEntry{
        name: img["name"],
        namespace: "linuxserver",
        description: img["description"],
        logo_url: img["project_logo"],
        version: img["version"],
        source: "linuxserver",
        full_ref: "lscr.io/linuxserver/#{img["name"]}:latest",
        project_url: img["project_url"],
        setup_url: config["application_setup"],
        categories: categories,
        architectures: architectures,
        required_ports: ports,
        required_volumes: volumes,
        default_env: %{"PUID" => "1000", "PGID" => "1000", "TZ" => "Etc/UTC"},
        required_env: [],
        stars: img["stars"] || 0,
        pulls: img["monthly_pulls"] || 0,
        official?: false,
        deprecated?: img["deprecated"] == true,
        auth_required?: false
      }
    end)
  end

  defp parse_response(_), do: []

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
