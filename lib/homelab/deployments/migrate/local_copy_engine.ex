defmodule Homelab.Deployments.Migrate.LocalCopyEngine do
  @moduledoc """
  In-process copy engine: clears `dest`, copies `source` into it, then proves
  the copy by comparing a checksum manifest of the source against one of the
  destination. Returns a proof or a fail-closed error.

  Used when the plane can read both paths directly. It does NOT preserve
  ownership (uid/gid) — `File.cp_r` copies content and mode but not owner — so
  data dirs that require a specific uid/gid (e.g. a Postgres data dir owned by
  999:999) should use the container engine, which runs `cp -a` as root.
  """

  @behaviour Homelab.Deployments.Migrate.CopyEngine

  alias Homelab.Deployments.Backups.Checksum

  @impl true
  def migrate(source, dest, _opts \\ []) do
    cond do
      not File.exists?(source) ->
        {:error, {:source_missing, source}}

      true ->
        with :ok <- copy(source, dest) do
          verify(source, dest)
        end
    end
  rescue
    e -> {:error, {:migrate_exception, Exception.message(e)}}
  end

  # Clear dest for a deterministic, idempotent copy (a partial prior run can't
  # leave stale files that would fail verification or leak into the volume).
  defp copy(source, dest) do
    File.rm_rf!(dest)
    File.mkdir_p!(dest)

    if File.dir?(source) do
      case File.cp_r(source, dest) do
        {:ok, _} -> :ok
        {:error, reason, path} -> {:error, {:copy_failed, reason, path}}
      end
    else
      File.cp!(source, Path.join(dest, Path.basename(source)))
      :ok
    end
  end

  defp verify(source, dest) do
    src = source_manifest(source)
    dst = Checksum.manifest(dest)

    case Checksum.compare(src, dst) do
      :ok ->
        {:ok,
         %{
           "files" => map_size(src),
           "bytes" => Checksum.total_bytes(src),
           "digest" => Checksum.digest(src),
           "verified" => true
         }}

      {:error, _} = err ->
        err
    end
  end

  # For a directory the manifest is keyed by path-relative-to-source; for a single
  # file we mirror how `copy/2` lands it (dest/<basename>) so the two compare.
  defp source_manifest(source) do
    if File.dir?(source) do
      Checksum.manifest(source)
    else
      %{Path.basename(source) => Checksum.file_entry(source)}
    end
  end
end
