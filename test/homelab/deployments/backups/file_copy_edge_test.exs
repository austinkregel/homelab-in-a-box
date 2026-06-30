defmodule Homelab.Deployments.Backups.FileCopyEdgeTest do
  @moduledoc """
  Edge cases for the reference `FileCopy` backup strategy not already covered by
  `file_copy_test.exs`: the missing-manifest verify path, idempotent re-backup
  that clears stale data, and the full artifact metadata shape. Pure filesystem,
  no Docker/DB.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Backups.FileCopy

  setup do
    base = Path.join(System.tmp_dir!(), "filecopy-edge-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    dest = Path.join(base, "dest")
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base, src: src, dest: dest}
  end

  test "artifact carries the full documented metadata shape", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "abcde")

    assert {:ok, artifact} = FileCopy.backup(src, dest)
    assert artifact["strategy"] == "file_copy"
    assert artifact["source"] == src
    assert artifact["path"] == dest
    assert artifact["files"] == 1
    assert artifact["bytes"] == 5
  end

  test "verify returns manifest_missing when the manifest file is absent", %{
    src: src,
    dest: dest
  } do
    File.write!(Path.join(src, "a.txt"), "hello")
    {:ok, artifact} = FileCopy.backup(src, dest)

    File.rm!(Path.join(dest, "manifest.json"))

    assert {:error, {:manifest_missing, _reason, _path}} = FileCopy.verify(artifact)
  end

  test "re-running backup clears stale data from a prior run", %{src: src, dest: dest} do
    File.write!(Path.join(src, "keep.txt"), "v1")
    {:ok, _} = FileCopy.backup(src, dest)

    # Simulate a previous backup that had an extra file.
    File.write!(Path.join([dest, "data", "stale.txt"]), "old")

    # Re-run: source no longer has stale.txt, so the fresh backup must drop it.
    {:ok, artifact} = FileCopy.backup(src, dest)
    refute File.exists?(Path.join([dest, "data", "stale.txt"]))
    assert artifact["files"] == 1
    assert :ok = FileCopy.verify(artifact)
  end

  test "an empty source directory backs up and verifies as zero files", %{src: src, dest: dest} do
    assert {:ok, artifact} = FileCopy.backup(src, dest)
    assert artifact["files"] == 0
    assert artifact["bytes"] == 0
    assert :ok = FileCopy.verify(artifact)
  end

  test "backup/verify round-trips with default opts arg", %{src: src, dest: dest} do
    File.write!(Path.join(src, "x"), "y")
    assert {:ok, artifact} = FileCopy.backup(src, dest, [])
    assert :ok = FileCopy.verify(artifact, [])
  end
end
