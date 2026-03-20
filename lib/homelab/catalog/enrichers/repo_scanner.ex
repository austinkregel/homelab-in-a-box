defmodule Homelab.Catalog.Enrichers.RepoScanner do
  @moduledoc """
  Scans GitHub repositories for docker-compose files, .env examples,
  and Dockerfiles to extract deployment metadata.
  """

  require Logger

  alias Homelab.Catalog.Enrichers.{ComposeParser, DockerfileParser}

  @compose_files ~w(
    docker-compose.yml
    docker-compose.yaml
    compose.yml
    compose.yaml
    docker-compose.example.yml
    docker-compose.example.yaml
  )

  @env_files ~w(
    .env.example
    .env.sample
    env.example
    .env.template
  )

  @spec scan(String.t()) :: {:ok, map()} | {:error, term()}
  def scan(project_url) when is_binary(project_url) do
    case parse_github_url(project_url) do
      {:ok, owner, repo} ->
        do_scan(owner, repo)

      :error ->
        {:error, :not_a_github_url}
    end
  end

  def scan(_), do: {:error, :no_project_url}

  defp parse_github_url(url) do
    case Regex.run(~r|github\.com/([^/]+)/([^/\#\?]+)|, url) do
      [_, owner, repo] ->
        repo = String.trim_trailing(repo, ".git")
        {:ok, owner, repo}

      _ ->
        :error
    end
  end

  defp do_scan(owner, repo) do
    tasks = [
      Task.async(fn -> fetch_compose(owner, repo) end),
      Task.async(fn -> fetch_env_example(owner, repo) end),
      Task.async(fn -> fetch_dockerfile(owner, repo) end),
      Task.async(fn -> fetch_readme_compose(owner, repo) end)
    ]

    [compose_result, env_result, dockerfile_result, readme_result] =
      Task.yield_many(tasks, 15_000)
      |> Enum.map(fn
        {_task, {:ok, result}} ->
          result

        {task, nil} ->
          Task.shutdown(task, :brutal_kill)
          nil

        _ ->
          nil
      end)

    merged = merge_scan_results(compose_result, env_result, dockerfile_result, readme_result)

    setup_url = "https://github.com/#{owner}/#{repo}"

    {:ok, Map.put(merged, :setup_url, setup_url)}
  end

  defp fetch_compose(owner, repo) do
    @compose_files
    |> Enum.find_value(fn file ->
      case fetch_raw_file(owner, repo, file) do
        {:ok, content} ->
          case ComposeParser.parse(content) do
            {:ok, result} -> result
            _ -> nil
          end

        _ ->
          nil
      end
    end)
  end

  defp fetch_env_example(owner, repo) do
    @env_files
    |> Enum.find_value(fn file ->
      case fetch_raw_file(owner, repo, file) do
        {:ok, content} -> parse_env_file(content)
        _ -> nil
      end
    end)
  end

  defp fetch_dockerfile(owner, repo) do
    case fetch_raw_file(owner, repo, "Dockerfile") do
      {:ok, content} ->
        case DockerfileParser.parse(content) do
          {:ok, result} -> result
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp fetch_raw_file(owner, repo, path) do
    branches = ["main", "master"]

    Enum.find_value(branches, fn branch ->
      url = "https://raw.githubusercontent.com/#{owner}/#{repo}/#{branch}/#{path}"

      case Req.get(url, receive_timeout: 10_000) do
        {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
          {:ok, body}

        _ ->
          nil
      end
    end)
  end

  defp parse_env_file(content) do
    content
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(fn line -> line == "" or String.starts_with?(line, "#") end)
    |> Enum.flat_map(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] ->
          key = String.trim(key)
          value = value |> String.trim() |> String.trim("\"") |> String.trim("'")
          [%{"key" => key, "value" => value}]

        _ ->
          []
      end
    end)
  end

  defp fetch_readme_compose(owner, repo) do
    case fetch_raw_file(owner, repo, "README.md") do
      {:ok, content} ->
        extract_compose_from_readme(content)

      _ ->
        case fetch_raw_file(owner, repo, "readme.md") do
          {:ok, content} -> extract_compose_from_readme(content)
          _ -> nil
        end
    end
  end

  defp extract_compose_from_readme(content) do
    yaml_blocks =
      Regex.scan(~r/```ya?ml\n(.*?)```/s, content, capture: :all_but_first)
      |> Enum.map(fn [block] -> String.trim(block) end)
      |> Enum.filter(fn block ->
        String.contains?(block, "services:") or String.contains?(block, "image:")
      end)

    Enum.find_value(yaml_blocks, fn block ->
      case ComposeParser.parse(block) do
        {:ok, result} when result.env != [] or result.ports != [] -> result
        _ -> nil
      end
    end)
  end

  defp merge_scan_results(compose_result, env_result, dockerfile_result, readme_result) do
    base = %{ports: [], volumes: [], env: [], depends_on: []}

    base
    |> merge_if_present(compose_result)
    |> merge_if_present(readme_result)
    |> merge_if_present(dockerfile_result)
    |> merge_env_file(env_result)
  end

  defp merge_if_present(acc, nil), do: acc

  defp merge_if_present(acc, result) when is_map(result) do
    %{
      ports: if(acc.ports == [], do: result[:ports] || [], else: acc.ports),
      volumes: if(acc.volumes == [], do: result[:volumes] || [], else: acc.volumes),
      env: merge_env_lists(acc.env, result[:env] || []),
      depends_on: Enum.uniq((acc[:depends_on] || []) ++ (result[:depends_on] || []))
    }
  end

  defp merge_env_file(acc, nil), do: acc

  defp merge_env_file(acc, env_vars) when is_list(env_vars) do
    %{acc | env: merge_env_lists(acc.env, env_vars)}
  end

  defp merge_env_lists(existing, new) do
    existing_keys = MapSet.new(existing, fn %{"key" => k} -> k end)

    unique_new =
      Enum.reject(new, fn %{"key" => k} -> MapSet.member?(existing_keys, k) end)

    existing ++ unique_new
  end
end
