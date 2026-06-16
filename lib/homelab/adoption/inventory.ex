defmodule Homelab.Adoption.Inventory do
  @moduledoc """
  Read-only scan of `Homelab.Adoption.source_root/`. Works without ZFS.
  Uses the filesystem when the path is visible to the BEAM process, or
  skips size measurement when not (e.g. container without a bind mount).
  """

  alias Homelab.{Adoption, Repo}
  alias Homelab.Adoption.AdoptedApp
  alias Homelab.Catalog

  def scan do
    root = Adoption.source_root()

    if File.dir?(root) do
      root
      |> File.ls!()
      |> Enum.filter(&app_directory?/1)
      |> Enum.map(&scan_app(root, &1))
      |> Enum.map(&persist/1)
      |> then(&{:ok, &1})
    else
      {:error, {:source_root_missing, root}}
    end
  end

  defp app_directory?(name), do: not String.starts_with?(name, ".")

  defp scan_app(root, slug) do
    path = Path.join(root, slug)
    _stat = File.stat!(path)
    size = dir_size_bytes(path)
    compose? = File.exists?(Path.join(path, "docker-compose.yml"))
    match = match_container(path, slug)
    template = suggest_template(match)

    %{
      slug: slug,
      source_path: path,
      size_bytes: size,
      classification: Adoption.classify(size) |> Atom.to_string(),
      has_compose: compose?,
      container_match: match,
      suggested_app_template_id: template && template.id,
      import_status: "discovered"
    }
  end

  defp dir_size_bytes(path) do
    if Homelab.Storage.available?() do
      case Homelab.Storage.Zfs.HostAgent.request("host.du_bytes", %{"path" => path}) do
        {:ok, %{"bytes" => b}} -> b
        _ -> du_fallback(path)
      end
    else
      du_fallback(path)
    end
  end

  defp du_fallback(path) do
    case System.cmd("du", ["-sb", path], stderr_to_stdout: true) do
      {out, 0} ->
        out |> String.split() |> List.first() |> Integer.parse() |> elem(0)

      _ ->
        nil
    end
  end

  defp match_container(path, slug) do
    case Homelab.Docker.Client.get("/containers/json?all=1") do
      {:ok, containers} when is_list(containers) ->
        containers
        |> Enum.find_value(fn c -> classify_match(c, path, slug) end)

      _ ->
        nil
    end
  end

  defp classify_match(container, path, slug) do
    labels = get_in(container, ["Labels"]) || %{}
    mounts = get_in(container, ["Mounts"]) || []

    cond do
      labels["homelab.legacy.appdata"] == Path.basename(path) ->
        %{"confidence" => "high", "reason" => "label", "container_id" => container["Id"]}

      Enum.any?(mounts, fn m -> m["Source"] == path end) ->
        %{"confidence" => "high", "reason" => "mount_source", "container_id" => container["Id"]}

      name_match?(container, slug) ->
        %{"confidence" => "low", "reason" => "name_fuzzy", "container_id" => container["Id"]}

      true ->
        nil
    end
  end

  defp name_match?(container, slug) do
    names = List.wrap(container["Names"])

    Enum.any?(names, fn n ->
      down = String.downcase(n)
      String.contains?(down, slug)
    end)
  end

  defp suggest_template(%{"container_id" => id}) when is_binary(id) do
    case Homelab.Docker.Client.get("/containers/#{id}/json") do
      {:ok, %{"Config" => %{"Image" => image}}} ->
        Catalog.list_app_templates()
        |> Enum.find(fn t -> t.image == image or String.contains?(image, t.slug) end)

      _ ->
        nil
    end
  end

  defp suggest_template(_), do: nil

  defp persist(attrs) do
    case Repo.get_by(AdoptedApp, source_path: attrs.source_path) do
      nil ->
        %AdoptedApp{} |> AdoptedApp.changeset(attrs) |> Repo.insert!()

      existing ->
        existing |> AdoptedApp.changeset(Map.drop(attrs, [:import_status])) |> Repo.update!()
    end
  end
end
