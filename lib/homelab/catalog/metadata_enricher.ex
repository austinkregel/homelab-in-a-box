defmodule Homelab.Catalog.MetadataEnricher do
  @moduledoc """
  Orchestrates on-demand metadata enrichment for catalog entries by running
  the Docker Registry image inspector and GitHub repo scanner concurrently,
  then merging results with priority ordering.

  Results are cached in :persistent_term so repeated views are instant.
  """

  require Logger

  alias Homelab.Catalog.CatalogEntry
  alias Homelab.Catalog.Enrichers.{ImageInspector, RepoScanner}

  @spec enrich(CatalogEntry.t(), keyword()) :: {:ok, CatalogEntry.t()}
  def enrich(%CatalogEntry{} = entry, opts \\ []) do
    cache_key = {:enrichment, entry.source, entry.name}

    case :persistent_term.get(cache_key, nil) do
      nil ->
        enriched = do_enrich(entry, opts)
        :persistent_term.put(cache_key, enriched)
        {:ok, enriched}

      cached ->
        {:ok, cached}
    end
  end

  defp do_enrich(entry, opts) do
    Logger.info("[MetadataEnricher] Enriching #{entry.name} (#{entry.full_ref})")
    result = run_enrichment(entry, opts)

    env_count = map_size(result.default_env) + length(result.required_env)
    port_count = length(result.required_ports)
    vol_count = length(result.required_volumes)

    Logger.info(
      "[MetadataEnricher] #{entry.name}: #{env_count} env vars, #{port_count} ports, #{vol_count} volumes"
    )

    result
  end

  defp run_enrichment(entry, opts) do
    progress_pid = Keyword.get(opts, :progress)

    notify_progress(progress_pid, "inspecting")

    image_task =
      if entry.full_ref && entry.full_ref != "" do
        Task.async(fn -> ImageInspector.inspect(entry.full_ref) end)
      else
        nil
      end

    image_result = await_task(image_task)

    project_url =
      cond do
        entry.project_url && entry.project_url != "" ->
          entry.project_url

        image_result ->
          labels = image_result[:labels] || %{}
          labels["org.opencontainers.image.source"] || labels["org.opencontainers.image.url"]

        true ->
          nil
      end

    notify_progress(progress_pid, "scanning")

    repo_task =
      if project_url && project_url != "" do
        Task.async(fn -> RepoScanner.scan(project_url) end)
      else
        nil
      end

    repo_result = await_task(repo_task)

    notify_progress(progress_pid, "merging")

    merge_into_entry(entry, image_result, repo_result)
  end

  defp notify_progress(nil, _stage), do: :ok
  defp notify_progress(pid, stage), do: send(pid, {:enrichment_progress, stage})

  defp await_task(nil), do: nil

  defp await_task(task) do
    case Task.yield(task, 20_000) do
      {:ok, {:ok, result}} ->
        result

      {:ok, {:error, reason}} ->
        Logger.debug("[MetadataEnricher] Enricher failed: #{inspect(reason)}")
        nil

      nil ->
        Task.shutdown(task, :brutal_kill)
        Logger.debug("[MetadataEnricher] Enricher timed out")
        nil
    end
  end

  defp merge_into_entry(entry, image_result, repo_result) do
    enriched_ports =
      pick_first_nonempty([
        repo_result && repo_result[:ports],
        image_result && image_result[:ports]
      ])

    enriched_volumes =
      pick_first_nonempty([
        repo_result && repo_result[:volumes],
        image_result && image_result[:volumes]
      ])

    env_vars = merge_env(image_result, repo_result)
    {enriched_default_env, enriched_required_env} = partition_env(env_vars)

    setup_url = entry.setup_url || (repo_result && repo_result[:setup_url])

    merged_ports = merge_lists_by_key(entry.required_ports, enriched_ports, "internal")
    merged_volumes = merge_lists_by_key(entry.required_volumes, enriched_volumes, "path")

    merged_default_env = Map.merge(enriched_default_env, entry.default_env)

    existing_env_keys = MapSet.new(Map.keys(entry.default_env) ++ entry.required_env)

    merged_required_env =
      (entry.required_env ++
         Enum.reject(enriched_required_env, &MapSet.member?(existing_env_keys, &1)))
      |> Enum.uniq()

    %CatalogEntry{
      entry
      | required_ports: merged_ports,
        required_volumes: merged_volumes,
        default_env: merged_default_env,
        required_env: merged_required_env,
        setup_url: setup_url
    }
  end

  defp merge_lists_by_key(existing, enriched, key) do
    existing_keys = MapSet.new(existing, fn item -> item[key] end)
    new_items = Enum.reject(enriched, fn item -> MapSet.member?(existing_keys, item[key]) end)
    existing ++ new_items
  end

  defp pick_first_nonempty(sources) do
    Enum.find(sources, [], fn
      list when is_list(list) and length(list) > 0 -> true
      _ -> false
    end)
  end

  defp merge_env(image_result, repo_result) do
    image_env = if image_result, do: image_result[:env] || [], else: []
    repo_env = if repo_result, do: repo_result[:env] || [], else: []

    seen = MapSet.new(repo_env, fn %{"key" => k} -> k end)

    unique_image =
      Enum.reject(image_env, fn %{"key" => k} -> MapSet.member?(seen, k) end)

    repo_env ++ unique_image
  end

  defp partition_env(env_vars) do
    default_env =
      env_vars
      |> Enum.filter(fn %{"value" => v} -> v != "" end)
      |> Enum.map(fn %{"key" => k, "value" => v} -> {k, v} end)
      |> Map.new()

    required_env =
      env_vars
      |> Enum.filter(fn %{"value" => v} -> v == "" end)
      |> Enum.map(fn %{"key" => k} -> k end)

    {default_env, required_env}
  end
end
