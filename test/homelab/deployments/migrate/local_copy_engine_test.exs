defmodule Homelab.Deployments.Migrate.LocalCopyEngineTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.LocalCopyEngine

  setup do
    base = Path.join(System.tmp_dir!(), "localcopy-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    dest = Path.join(base, "dest")
    File.mkdir_p!(src)
    on_exit(fn -> File.rm_rf(base) end)
    %{src: src, dest: dest}
  end

  test "copies a tree to dest and proves it identical", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "hello")
    File.mkdir_p!(Path.join(src, "sub"))
    File.write!(Path.join([src, "sub", "b.bin"]), String.duplicate("x", 3_000_000))

    assert {:ok, proof} = LocalCopyEngine.migrate(src, dest)
    assert proof["verified"] == true
    assert proof["files"] == 2
    assert proof["bytes"] == 5 + 3_000_000
    assert is_binary(proof["digest"])

    assert File.read!(Path.join([dest, "sub", "b.bin"])) |> byte_size() == 3_000_000
  end

  test "copies a single file", %{src: src, dest: dest} do
    file = Path.join(src, "app.env")
    File.write!(file, "K=V")

    assert {:ok, proof} = LocalCopyEngine.migrate(file, dest)
    assert proof["files"] == 1
    assert File.read!(Path.join(dest, "app.env")) == "K=V"
  end

  test "clears stale dest content for an idempotent re-run", %{src: src, dest: dest} do
    File.write!(Path.join(src, "a.txt"), "hello")
    File.mkdir_p!(dest)
    File.write!(Path.join(dest, "stale.txt"), "old junk")

    assert {:ok, proof} = LocalCopyEngine.migrate(src, dest)
    assert proof["files"] == 1
    refute File.exists?(Path.join(dest, "stale.txt"))
  end

  test "errors when the source is missing", %{dest: dest} do
    assert {:error, {:source_missing, _}} = LocalCopyEngine.migrate("/no/such/src", dest)
  end
end
