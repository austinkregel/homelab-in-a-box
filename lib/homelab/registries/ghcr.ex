defmodule Homelab.Registries.GHCR do
  @moduledoc "Container registry driver for GitHub Container Registry (GHCR)."

  @behaviour Homelab.Behaviours.ContainerRegistry

  @impl true
  def driver_id, do: "ghcr"

  @impl true
  def display_name, do: "GitHub (GHCR)"

  @impl true
  def description, do: "GitHub Container Registry for GitHub-hosted packages"

  @impl true
  def capabilities do
    base = [:search, :list_tags]
    if configured?(), do: [:pull_auth | base], else: base
  end

  @impl true
  def search(query, _opts \\ []) do
    headers = auth_headers()

    # Try orgs first, then users
    org_url =
      "https://api.github.com/orgs/#{URI.encode_www_form(query)}/packages?package_type=container"

    user_url =
      "https://api.github.com/users/#{URI.encode_www_form(query)}/packages?package_type=container"

    with {:error, _} <- fetch_packages(org_url, headers, query),
         {:error, _} <- fetch_packages(user_url, headers, query) do
      {:error, :not_found}
    end
  end

  @impl true
  def list_tags(image, _opts \\ []) do
    [owner | rest] = String.split(image, "/")
    package = Enum.join(rest, "/")

    if package == "" do
      {:error, :invalid_image}
    else
      # Try orgs first, then users
      org_url = "https://api.github.com/orgs/#{owner}/packages/container/#{package}/versions"
      user_url = "https://api.github.com/users/#{owner}/packages/container/#{package}/versions"

      with {:error, _} <- fetch_versions(org_url),
           {:error, _} <- fetch_versions(user_url) do
        {:error, :not_found}
      end
    end
  end

  @impl true
  def full_image_ref(name, tag), do: "ghcr.io/#{name}:#{tag}"

  @impl true
  def pull_auth_config do
    case Homelab.Settings.get("ghcr_token") do
      nil -> {:error, :not_configured}
      token -> {:ok, %{"username" => "token", "password" => token, "serveraddress" => "ghcr.io"}}
    end
  end

  @impl true
  def configured?, do: Homelab.Settings.get("ghcr_token") != nil

  # --- Private ---

  defp auth_headers do
    case Homelab.Settings.get("ghcr_token") do
      nil -> []
      token -> [{"authorization", "Bearer #{token}"}]
    end
  end

  defp fetch_packages(url, headers, namespace) do
    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        entries =
          Enum.map(body, fn pkg ->
            name = pkg["name"] || ""

            %Homelab.Catalog.CatalogEntry{
              name: name,
              namespace: namespace,
              description: nil,
              logo_url: nil,
              version: nil,
              source: "ghcr",
              full_ref: "ghcr.io/#{namespace}/#{name}:latest",
              project_url: pkg["html_url"],
              categories: [],
              architectures: [],
              stars: 0,
              pulls: 0,
              official?: false,
              deprecated?: false,
              auth_required?: false
            }
          end)

        {:ok, entries}

      {:ok, %{status: 200, body: body}} when is_map(body) ->
        # Sometimes GitHub returns a single package as a map
        entries = [package_to_entry(body, namespace)]
        {:ok, entries}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp package_to_entry(pkg, namespace) do
    name = pkg["name"] || ""

    %Homelab.Catalog.CatalogEntry{
      name: name,
      namespace: namespace,
      description: nil,
      logo_url: nil,
      version: nil,
      source: :ghcr,
      full_ref: "ghcr.io/#{namespace}/#{name}:latest",
      project_url: pkg["html_url"],
      categories: [],
      architectures: [],
      stars: 0,
      pulls: 0,
      official?: false,
      deprecated?: false,
      auth_required?: false
    }
  end

  defp fetch_versions(url) do
    headers = auth_headers()

    case Req.get(url, headers: headers) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        tags =
          body
          |> Enum.flat_map(fn version ->
            metadata = version["metadata"] || %{}
            container = metadata["container"] || %{}
            tag_names = container["tags"] || []

            Enum.map(tag_names, fn tag ->
              %Homelab.Catalog.TagInfo{
                tag: tag,
                digest: version["name"],
                last_updated: version["created_at"],
                size_bytes: nil,
                architectures: []
              }
            end)
          end)

        {:ok, tags}

      {:ok, %{status: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
