defmodule Homelab.Deployments.Backups.FileCopyTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Backups.FileCopy

  setup do
    base = Path.join(System.tmp_dir!(), "filecopy-test-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    dest = Path.join(base, "dest")
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(base) end)
    %{src: src, dest: dest}
  end

  test "backs up a directory tree and verifies it", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "hello")
    File.mkdir_p!(Path.join(src, "sub"))
    File.write!(Path.join([src, "sub", "b.txt"]), String.duplicate("x", 5_000_000))

    assert {:ok, artifact} = FileCopy.backup(src, dest)
    assert artifact["files"] == 2
    assert artifact["bytes"] == 5 + 5_000_000
    assert File.exists?(Path.join([dest, "data", "a.txt"]))
    assert File.exists?(Path.join(dest, "manifest.json"))

    assert :ok = FileCopy.verify(artifact)
  end

  test "backs up a single file", %{src: src, dest: dest} do
    file = Path.join(src, "only.env")
    File.write!(file, "SECRET=1")

    assert {:ok, artifact} = FileCopy.backup(file, dest)
    assert artifact["files"] == 1
    assert File.read!(Path.join([dest, "data", "only.env"])) == "SECRET=1"
    assert :ok = FileCopy.verify(artifact)
  end

  test "verify FAILS when the stored copy is corrupted after backup", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "hello")
    {:ok, artifact} = FileCopy.backup(src, dest)
    assert :ok = FileCopy.verify(artifact)

    # Tamper with the stored backup.
    File.write!(Path.join([dest, "data", "a.txt"]), "tampered")

    assert {:error, {:verify_mismatch, %{altered: ["a.txt"]}}} = FileCopy.verify(artifact)
  end

  test "verify FAILS when a backed-up file goes missing", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "hello")
    {:ok, artifact} = FileCopy.backup(src, dest)

    File.rm!(Path.join([dest, "data", "a.txt"]))

    assert {:error, {:verify_mismatch, %{missing: ["a.txt"]}}} = FileCopy.verify(artifact)
  end

  test "backup errors when the source does not exist", %{dest: dest} do
    assert {:error, {:source_missing, _}} = FileCopy.backup("/no/such/path", dest)
  end
end
