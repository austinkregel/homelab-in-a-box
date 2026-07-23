defmodule Homelab.Catalog.Tags do
  @moduledoc """
  Which versions of an image an operator can actually choose.

  `list_tags/2` has been declared on `Homelab.Behaviours.ContainerRegistry` and
  implemented by every registry driver since they were written, and nothing ever
  called it — the version picker's backend existed before the picker did. This
  module is the missing caller: it maps an image reference to the driver that hosts
  it and asks that driver what tags exist.

  Two rules it exists to enforce:

    * **Never raise.** A tag list is a convenience on top of a free-text field. A
      registry that is slow, rate-limiting, unreachable, or returning a shape the
      driver did not expect must degrade to "no list available", never take out the
      Settings page the operator is trying to fix something else on.
    * **Never claim support it does not have.** A driver that does not advertise
      `:list_tags`, a self-hosted registry, an unrecognised host, or a digest-pinned
      ref all resolve to `{:error, :unsupported}` — which the UI renders as "type a
      tag" rather than as a failure.
  """

  alias Homelab.Catalog.ImageRef
  alias Homelab.Config

  # Registry APIs page; the drivers ask for 50. Showing every tag of a busy image is
  # not useful anyway — an operator picking a version wants the recent ones.
  @default_limit 50

  @doc """
  Tags available for an image reference, newest first.

  Returns `{:error, :unsupported}` when the ref's registry has no tag API we can
  use, and `{:error, reason}` when the registry was asked and did not answer.
  """
  @spec available_for(String.t(), keyword()) ::
          {:ok, [Homelab.Catalog.TagInfo.t()]} | {:error, :unsupported | term()}
  def available_for(image_ref, opts \\ []) when is_binary(image_ref) do
    with {:ok, repo} <- repo_for(image_ref),
         {:ok, driver} <- driver_for(image_ref),
         {:ok, tags} <- safe_list_tags(driver, repo, opts) do
      {:ok, tags |> Enum.filter(&taggable?/1) |> sort_newest_first() |> take(opts)}
    end
  end

  @doc """
  The registry driver that hosts an image ref, if it can list tags.

  Public because the UI needs to know whether to offer a picker at all before it
  spends a request finding out.
  """
  @spec driver_for(String.t()) :: {:ok, module()} | {:error, :unsupported}
  def driver_for(image_ref) when is_binary(image_ref) do
    driver_id = Config.registry_for_image(image_ref)

    # `Code.ensure_loaded?/1` before `function_exported?/3`: in a release, modules
    # load lazily and `function_exported?/3` answers FALSE for a module that simply
    # has not been loaded yet. Config.active_driver/2 documents the same trap.
    Config.registries()
    |> Enum.find(fn mod ->
      Code.ensure_loaded?(mod) and
        function_exported?(mod, :driver_id, 0) and
        mod.driver_id() == driver_id and
        lists_tags?(mod)
    end)
    |> case do
      nil -> {:error, :unsupported}
      mod -> {:ok, mod}
    end
  end

  @doc "True when a tag picker can be offered for this reference at all."
  @spec supported?(String.t()) :: boolean()
  def supported?(image_ref) when is_binary(image_ref) do
    match?({:ok, _}, repo_for(image_ref)) and match?({:ok, _}, driver_for(image_ref))
  end

  def supported?(_image_ref), do: false

  # --- Private ---

  # A digest-pinned ref has no tag to move; ImageRef rejects it here rather than
  # letting us ask a registry for tags we would not be able to apply.
  defp repo_for(image_ref) do
    case ImageRef.registry_repo(image_ref) do
      {:ok, repo} -> {:ok, repo}
      {:error, :invalid} -> {:error, :unsupported}
    end
  end

  defp lists_tags?(mod) do
    function_exported?(mod, :capabilities, 0) and :list_tags in mod.capabilities()
  end

  # A driver talks to a third party over the network. Req raises on some transport
  # failures rather than returning them, and a driver's body-parsing clause can
  # FunctionClauseError on an unexpected shape. Neither is worth a 500 on a page
  # whose free-text field works regardless.
  defp safe_list_tags(driver, repo, opts) do
    case driver.list_tags(repo, opts) do
      {:ok, tags} when is_list(tags) -> {:ok, tags}
      {:error, reason} -> {:error, reason}
      other -> {:error, {:unexpected, other}}
    end
  rescue
    error -> {:error, {:exception, Exception.message(error)}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    thrown -> {:error, {:throw, thrown}}
  end

  defp taggable?(%{tag: tag}) when is_binary(tag), do: String.trim(tag) != ""
  defp taggable?(_), do: false

  # Newest first, with undated tags last rather than dropped — GHCR and ECR both
  # return entries with no usable timestamp, and a tag with no date is still a tag
  # the operator may need.
  defp sort_newest_first(tags) do
    Enum.sort_by(tags, &sort_key/1, :desc)
  end

  defp sort_key(%{last_updated: value}), do: {dated?(value), timestamp(value)}

  defp dated?(value), do: if(timestamp(value) == 0, do: 0, else: 1)

  # `last_updated` is whatever the registry returned: Docker Hub and GHCR send an
  # ISO8601 string, ECR sends an epoch number. Anything unparseable sorts as undated.
  defp timestamp(%DateTime{} = dt), do: DateTime.to_unix(dt)
  defp timestamp(value) when is_integer(value), do: value
  defp timestamp(value) when is_float(value), do: trunc(value)

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, dt, _offset} -> DateTime.to_unix(dt)
      {:error, _reason} -> 0
    end
  end

  defp timestamp(_value), do: 0

  defp take(tags, opts) do
    Enum.take(tags, Keyword.get(opts, :limit, @default_limit))
  end
end
