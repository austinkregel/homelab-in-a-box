defmodule Homelab.WorkbenchTest do
  use ExUnit.Case, async: true

  alias Homelab.Workbench

  # Each test gets its own workspace root + user id so they never collide.
  setup do
    root = Path.join(System.tmp_dir!(), "workbench-test-#{System.unique_integer([:positive])}")
    prev = Application.get_env(:homelab, :workbench)

    Application.put_env(:homelab, :workbench,
      root: root,
      quota_bytes: 1_000,
      ttl_hours: 24
    )

    on_exit(fn ->
      File.rm_rf(root)
      Application.put_env(:homelab, :workbench, prev)
    end)

    {:ok, root: root, user_id: System.unique_integer([:positive])}
  end

  defp write_tmp(content) do
    path = Path.join(System.tmp_dir!(), "wb-src-#{System.unique_integer([:positive])}")
    File.write!(path, content)
    on_exit(fn -> File.rm(path) end)
    path
  end

  describe "workspace_dir/1" do
    test "is keyed by user id under the configured root", %{root: root, user_id: uid} do
      assert Workbench.workspace_dir(uid) == Path.join(root, "user-#{uid}")
    end
  end

  describe "add_file/3 + list_files/1" do
    test "copies a file into the workspace and lists it", %{user_id: uid} do
      src = write_tmp("hello world")

      assert {:ok, %{name: "notes.txt", size: 11}} = Workbench.add_file(uid, "notes.txt", src)

      assert [%{name: "notes.txt", size: 11, path: path}] = Workbench.list_files(uid)
      assert File.read!(path) == "hello world"
    end

    test "rejects a name with a .. traversal segment", %{user_id: uid} do
      src = write_tmp("x")
      assert {:error, :invalid_name} = Workbench.add_file(uid, "../escape.txt", src)
      assert Workbench.list_files(uid) == []
    end

    test "rejects an absolute name", %{user_id: uid} do
      src = write_tmp("x")
      assert {:error, :invalid_name} = Workbench.add_file(uid, "/etc/passwd", src)
    end

    test "enforces the quota and writes nothing on overflow", %{user_id: uid} do
      src = write_tmp(String.duplicate("a", 1_001))
      assert {:error, :quota_exceeded} = Workbench.add_file(uid, "big.bin", src)
      assert Workbench.list_files(uid) == []
    end

    test "replacing a same-named file frees its bytes for the quota check", %{user_id: uid} do
      first = write_tmp(String.duplicate("a", 900))
      assert {:ok, _} = Workbench.add_file(uid, "f", first)

      # A second 900-byte file under a new name would overflow 1000...
      second = write_tmp(String.duplicate("b", 900))
      assert {:error, :quota_exceeded} = Workbench.add_file(uid, "g", second)

      # ...but replacing "f" is fine since its bytes are reclaimed.
      assert {:ok, _} = Workbench.add_file(uid, "f", second)
      assert Workbench.total_size(uid) == 900
    end
  end

  describe "delete_file/2 + total_size/1" do
    test "removes a file and updates the total", %{user_id: uid} do
      assert {:ok, _} = Workbench.add_file(uid, "a.txt", write_tmp("abc"))
      assert Workbench.total_size(uid) == 3

      assert :ok = Workbench.delete_file(uid, "a.txt")
      assert Workbench.total_size(uid) == 0
      assert Workbench.list_files(uid) == []
    end

    test "deleting a missing file is still :ok", %{user_id: uid} do
      assert :ok = Workbench.delete_file(uid, "nope.txt")
    end
  end

  describe "quota_bytes/0" do
    test "reads the configured quota" do
      assert Workbench.quota_bytes() == 1_000
    end
  end

  describe "purge_stale/0" do
    test "removes workspaces older than the TTL, keeps fresh ones", %{root: root, user_id: uid} do
      Application.put_env(:homelab, :workbench, root: root, quota_bytes: 1_000, ttl_hours: 0)

      assert {:ok, _} = Workbench.add_file(uid, "old.txt", write_tmp("old"))
      assert File.dir?(Workbench.workspace_dir(uid))

      # ttl_hours: 0 means anything mtime < now is stale.
      assert Workbench.purge_stale() >= 1
      refute File.dir?(Workbench.workspace_dir(uid))
    end

    test "keeps workspaces within the TTL", %{root: root, user_id: uid} do
      Application.put_env(:homelab, :workbench, root: root, quota_bytes: 1_000, ttl_hours: 24)

      assert {:ok, _} = Workbench.add_file(uid, "fresh.txt", write_tmp("fresh"))
      assert Workbench.purge_stale() == 0
      assert File.dir?(Workbench.workspace_dir(uid))
    end
  end
end
