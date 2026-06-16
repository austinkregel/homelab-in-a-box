defmodule Homelab.Storage.Dataset do
  @moduledoc """
  ZFS dataset path construction and segment sanitization (decision §2).
  Safe to call without ZFS installed — only manipulates strings.
  """

  @max_segment_length 56
  @max_full_path_length 220

  @doc """
  Sanitizes a tenant/app/project slug for use as a ZFS dataset segment.

  Rules: lowercase; only `[a-z0-9_-]`; collapse `_` runs; trim edges;
  max 56 chars; empty or colliding names get an 8-char sha256 suffix.
  """
  @spec sanitize_segment(String.t(), existing :: MapSet.t() | nil) :: String.t()
  def sanitize_segment(slug, existing \\ nil) when is_binary(slug) do
    base =
      slug
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9_-]/, "_")
      |> String.replace(~r/_+/, "_")
      |> String.trim("_")
      |> String.trim("-")

    base =
      if base == "" do
        hash_suffix(slug)
      else
        String.slice(base, 0, @max_segment_length)
      end

    case existing do
      %MapSet{} = set ->
        if MapSet.member?(set, base) do
          base <> "-" <> hash_suffix(slug)
        else
          base
        end

      _ ->
        base
    end
  end

  @doc "Builds a dataset path under `pool` and validates total length."
  @spec path(pool :: String.t(), segments :: [String.t()]) ::
          {:ok, String.t()} | {:error, :path_too_long | :invalid_segment}
  def path(pool, segments) when is_binary(pool) and is_list(segments) do
    existing = MapSet.new()

    {sanitized, _} =
      Enum.map_reduce(segments, existing, fn seg, acc ->
        s = sanitize_segment(seg, acc)
        {s, MapSet.put(acc, s)}
      end)

    full = ([pool] ++ sanitized) |> Enum.join("/")

    if byte_size(full) > @max_full_path_length do
      {:error, :path_too_long}
    else
      {:ok, full}
    end
  end

  @doc "Default import dataset for a tenant/app (used when ZFS is available later)."
  def import_path(pool, tenant_slug, app_slug) do
    path(pool, ["imports", tenant_slug, app_slug])
  end

  @doc "Default appdata dataset path."
  def appdata_path(pool, tenant_slug, app_slug) do
    path(pool, ["appdata", tenant_slug, app_slug])
  end

  defp hash_suffix(input) do
    :crypto.hash(:sha256, input) |> Base.encode16(case: :lower) |> String.slice(0, 8)
  end
end
