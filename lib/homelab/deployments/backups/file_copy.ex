defmodule Homelab.Deployments.Backups.FileCopy do
  @moduledoc """
  Copy-based backup with a checksum manifest, for `:preserve` file trees and
  cold (stopped-container) data dirs.

  `backup/3` copies `source` to `dest/data` and writes `dest/manifest.json` — a
  per-file `{size, sha256}` map. `verify/2` re-reads the stored copy, recomputes
  every checksum, and confirms it matches the manifest exactly (no missing,
  extra, or altered files). A match proves the backup is a faithful, restorable
  copy: restoring is `File.cp_r(dest/data, target)`.

  This is the reference strategy. Production-scale trees (e.g. the 46 GB GitLab
  dir) should swap in an rsync/restic strategy behind the same behaviour; this
  one is exact and dependency-free, which is what the gate needs to be trustworthy
  and testable.
  """

  @behaviour Homelab.Deployments.Backups.Strategy

  alias Homelab.Deployments.Backups.Checksum

  @manifest "manifest.json"
  @data_subdir "data"

  @impl true
  def backup(source, dest, _opts \\ []) do
    cond do
      not exists?(source) ->
        {:error, {:source_missing, source}}

      true ->
        data_dir = Path.join(dest, @data_subdir)

        with :ok <- File.mkdir_p(dest),
             :ok <- copy_tree(source, data_dir),
             manifest = Checksum.manifest(data_dir),
             :ok <- write_manifest(dest, manifest) do
          {:ok,
           %{
             "strategy" => "file_copy",
             "source" => source,
             "path" => dest,
             "files" => map_size(manifest),
             "bytes" => Checksum.total_bytes(manifest)
           }}
        end
    end
  rescue
    e -> {:error, {:backup_exception, Exception.message(e)}}
  end

  @impl true
  def verify(%{"path" => dest}, _opts \\ []) do
    data_dir = Path.join(dest, @data_subdir)

    with {:ok, recorded} <- read_manifest(dest) do
      Checksum.compare(recorded, Checksum.manifest(data_dir))
    end
  rescue
    e -> {:error, {:verify_exception, Exception.message(e)}}
  end

  # --- copy -----------------------------------------------------------------

  defp copy_tree(source, data_dir) do
    File.rm_rf!(data_dir)

    if File.dir?(source) do
      File.mkdir_p!(data_dir)

      case File.cp_r(source, data_dir) do
        {:ok, _} -> :ok
        {:error, reason, path} -> {:error, {:copy_failed, reason, path}}
      end
    else
      # Single-file bind: store it under data/<basename>.
      File.mkdir_p!(data_dir)
      File.cp!(source, Path.join(data_dir, Path.basename(source)))
      :ok
    end
  end

  # --- manifest -------------------------------------------------------------

  defp write_manifest(dest, manifest) do
    File.write(Path.join(dest, @manifest), Jason.encode!(manifest))
  end

  defp read_manifest(dest) do
    path = Path.join(dest, @manifest)

    case File.read(path) do
      {:ok, body} -> {:ok, Jason.decode!(body)}
      {:error, reason} -> {:error, {:manifest_missing, reason, path}}
    end
  end

  # --- fs helpers -----------------------------------------------------------

  defp exists?(path), do: File.exists?(path)
end
