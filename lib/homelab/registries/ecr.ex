defmodule Homelab.Registries.ECR do
  @moduledoc "Container registry driver for AWS ECR Public Gallery."

  @behaviour Homelab.Behaviours.ContainerRegistry

  @base_url "https://api.us-east-1.gallery.ecr.aws"

  @impl true
  def driver_id, do: "ecr"

  @impl true
  def display_name, do: "AWS ECR Public"

  @impl true
  def description, do: "AWS Elastic Container Registry public gallery"

  @impl true
  def capabilities, do: [:search, :list_tags]

  @impl true
  def search(query, opts \\ []) do
    case describe_repositories(opts) do
      {:ok, repos} ->
        query_lower = String.downcase(query)

        filtered =
          Enum.filter(repos, fn repo ->
            name = repo["repositoryName"] || ""
            desc = repo["repositoryDescription"] || ""

            String.contains?(String.downcase(name), query_lower) ||
              String.contains?(String.downcase(desc), query_lower)
          end)

        entries =
          Enum.map(Enum.take(filtered, 25), fn repo ->
            name = repo["repositoryName"] || ""

            %Homelab.Catalog.CatalogEntry{
              name: name,
              namespace: nil,
              description: repo["repositoryDescription"],
              logo_url: nil,
              version: nil,
              source: "ecr",
              full_ref: "public.ecr.aws/#{name}:latest",
              project_url: nil,
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

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def list_tags(image, _opts \\ []) do
    body = %{
      "repositoryName" => image,
      "maxResults" => 50
    }

    headers = [
      {"content-type", "application/x-amz-json-1.1"},
      {"x-amz-target", "SpencerFrontendService.DescribeImageTags"}
    ]

    case Req.post("#{@base_url}/", json: body, headers: headers) do
      {:ok, %{status: 200, body: %{"imageTagDetails" => details}}} ->
        tags =
          Enum.map(details, fn d ->
            %Homelab.Catalog.TagInfo{
              tag: d["imageTag"],
              digest: d["imageDigest"],
              last_updated: d["imagePushedAt"],
              size_bytes: d["imageSizeInBytes"],
              architectures: []
            }
          end)

        {:ok, tags}

      {:ok, %{status: 200, body: body}} ->
        # Some ECR versions return "imageTags" instead of "imageTagDetails"
        tags = parse_image_tags(body)
        {:ok, tags}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def full_image_ref(name, tag), do: "public.ecr.aws/#{name}:#{tag}"

  # --- Private ---

  defp describe_repositories(opts) do
    next_token = Keyword.get(opts, :next_token)
    max_results = Keyword.get(opts, :max_results, 100)

    body =
      %{"maxResults" => max_results}
      |> maybe_put("nextToken", next_token)

    headers = [
      {"content-type", "application/x-amz-json-1.1"},
      {"x-amz-target", "SpencerFrontendService.DescribeRepositories"}
    ]

    case Req.post("#{@base_url}/", json: body, headers: headers) do
      {:ok, %{status: 200, body: %{"repositories" => repos}}} ->
        {:ok, repos}

      {:ok, %{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)

  defp parse_image_tags(%{"imageTagDetails" => details}) do
    Enum.map(details, fn d ->
      %Homelab.Catalog.TagInfo{
        tag: d["imageTag"],
        digest: d["imageDigest"],
        last_updated: d["imagePushedAt"],
        size_bytes: d["imageSizeInBytes"],
        architectures: []
      }
    end)
  end

  defp parse_image_tags(_), do: []
end
