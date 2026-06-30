defmodule Homelab.Deployments.Backups.Checksum do
  @moduledoc """
  Content checksums for proving a copy is faithful — shared by the backup gate
  (`FileCopy`) and the migration copy (`Migrate.LocalCopyEngine`).

  `manifest/1` walks a directory and returns `%{relative_path => %{"size", "sha256"}}`.
  Comparing two manifests (`compare/2`) proves two trees are byte-identical: a
  match means no file is missing, extra, or altered. `digest/1` rolls a manifest
  into a single fingerprint for compact recording.
  """

  @chunk 2 * 1024 * 1024

  @doc "Per-file `{size, sha256}` map for every file under `root` (empty if absent)."
  def manifest(root) do
    root
    |> walk()
    |> Map.new(fn file ->
      {Path.relative_to(file, root), %{"size" => size(file), "sha256" => sha256(file)}}
    end)
  end

  @doc "The `{size, sha256}` entry for one file."
  def file_entry(path), do: %{"size" => size(path), "sha256" => sha256(path)}

  @doc "A single stable fingerprint for a whole manifest."
  def digest(manifest) do
    manifest
    |> Enum.sort()
    |> :erlang.term_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc "Total bytes across a manifest."
  def total_bytes(manifest), do: manifest |> Map.values() |> Enum.reduce(0, &(&1["size"] + &2))

  @doc "`:ok` if two manifests are identical, else the diff."
  def compare(a, a), do: :ok

  def compare(recorded, actual) do
    missing = Map.keys(recorded) -- Map.keys(actual)
    extra = Map.keys(actual) -- Map.keys(recorded)

    altered =
      for k <- Map.keys(recorded), Map.has_key?(actual, k), recorded[k] != actual[k], do: k

    {:error, {:verify_mismatch, %{missing: missing, extra: extra, altered: altered}}}
  end

  defp walk(path) do
    cond do
      File.regular?(path) -> [path]
      File.dir?(path) -> path |> File.ls!() |> Enum.flat_map(&walk(Path.join(path, &1)))
      true -> []
    end
  end

  defp size(path) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} -> size
      _ -> 0
    end
  end

  defp sha256(path) do
    path
    |> File.stream!([], @chunk)
    |> Enum.reduce(:crypto.hash_init(:sha256), &:crypto.hash_update(&2, &1))
    |> :crypto.hash_final()
    |> Base.encode16(case: :lower)
  end
end
