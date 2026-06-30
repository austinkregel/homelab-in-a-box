defmodule Homelab.Deployments.Backups.ChecksumTest do
  @moduledoc """
  Pure file-checksum tests for `Homelab.Deployments.Backups.Checksum`.

  Exercises `manifest/1` (walk, per-file size/sha256, empty/missing roots),
  `file_entry/1`, `digest/1` stability, `total_bytes/1`, and `compare/2`'s
  match / missing / extra / altered branches. All fixtures are real temp files
  cleaned up in `on_exit`.
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Backups.Checksum

  setup do
    root =
      Path.join(System.tmp_dir!(), "checksum_test_#{System.unique_integer([:positive])}")

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write(root, rel, contents) do
    path = Path.join(root, rel)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
    path
  end

  # -- manifest/1 ----------------------------------------------------------

  describe "manifest/1" do
    test "returns empty map for a missing root" do
      missing =
        Path.join(System.tmp_dir!(), "does_not_exist_#{System.unique_integer([:positive])}")

      assert Checksum.manifest(missing) == %{}
    end

    test "returns empty map for an empty directory", %{root: root} do
      assert Checksum.manifest(root) == %{}
    end

    test "treats a single regular file root as one relative-'.' entry", %{root: root} do
      file = write(root, "solo.txt", "hello")
      manifest = Checksum.manifest(file)

      # Path.relative_to(file, file) yields "." for the file-as-root case
      assert Map.keys(manifest) == ["."]
      assert manifest["."]["size"] == byte_size("hello")
    end

    test "maps relative paths to size and sha256 for every nested file", %{root: root} do
      write(root, "a.txt", "aaa")
      write(root, "sub/b.txt", "bbbb")

      manifest = Checksum.manifest(root)

      assert Map.keys(manifest) |> Enum.sort() == ["a.txt", "sub/b.txt"]
      assert manifest["a.txt"]["size"] == 3
      assert manifest["sub/b.txt"]["size"] == 4

      expected_sha = :crypto.hash(:sha256, "aaa") |> Base.encode16(case: :lower)
      assert manifest["a.txt"]["sha256"] == expected_sha
    end

    test "size 0 and known empty-string sha for an empty file", %{root: root} do
      write(root, "empty", "")
      manifest = Checksum.manifest(root)

      assert manifest["empty"]["size"] == 0
      # sha256 of the empty byte stream
      assert manifest["empty"]["sha256"] ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end

    test "differs when content differs, identical when content identical", %{root: root} do
      write(root, "x", "one")
      m1 = Checksum.manifest(root)

      File.write!(Path.join(root, "x"), "two")
      m2 = Checksum.manifest(root)

      assert m1["x"]["sha256"] != m2["x"]["sha256"]

      File.write!(Path.join(root, "x"), "one")
      m3 = Checksum.manifest(root)
      assert m1["x"]["sha256"] == m3["x"]["sha256"]
    end

    test "handles content larger than the 2MiB chunk boundary", %{root: root} do
      big = :binary.copy("z", 3 * 1024 * 1024)
      write(root, "big.bin", big)

      manifest = Checksum.manifest(root)
      assert manifest["big.bin"]["size"] == byte_size(big)

      expected = :crypto.hash(:sha256, big) |> Base.encode16(case: :lower)
      assert manifest["big.bin"]["sha256"] == expected
    end
  end

  # -- file_entry/1 --------------------------------------------------------

  describe "file_entry/1" do
    test "returns size and sha256 matching a direct hash", %{root: root} do
      path = write(root, "f.txt", "payload")
      entry = Checksum.file_entry(path)

      assert entry["size"] == byte_size("payload")
      assert entry["sha256"] == :crypto.hash(:sha256, "payload") |> Base.encode16(case: :lower)
    end

    test "raises for a missing file (sha256 streams the absent path)" do
      # size/1 swallows the stat error, but sha256/1 streams the file and a
      # missing path makes File.stream! raise -> file_entry/1 is not safe for
      # absent files (only manifest/1 is, via its walk guard).
      assert_raise File.Error, fn ->
        Checksum.file_entry(
          Path.join(System.tmp_dir!(), "absent_#{System.unique_integer([:positive])}")
        )
      end
    end
  end

  # -- digest/1 ------------------------------------------------------------

  describe "digest/1" do
    test "is stable for the same manifest", %{root: root} do
      write(root, "a", "1")
      write(root, "b", "2")
      manifest = Checksum.manifest(root)

      assert Checksum.digest(manifest) == Checksum.digest(manifest)
    end

    test "is order-independent (sorts before hashing)" do
      a = %{"x" => %{"size" => 1, "sha256" => "aa"}, "y" => %{"size" => 2, "sha256" => "bb"}}

      reordered = %{
        "y" => %{"size" => 2, "sha256" => "bb"},
        "x" => %{"size" => 1, "sha256" => "aa"}
      }

      assert Checksum.digest(a) == Checksum.digest(reordered)
    end

    test "changes when any entry changes" do
      base = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      changed = %{"x" => %{"size" => 1, "sha256" => "bb"}}

      assert Checksum.digest(base) != Checksum.digest(changed)
    end

    test "is a lowercase hex sha256 string" do
      digest = Checksum.digest(%{"x" => %{"size" => 0, "sha256" => "aa"}})
      assert digest =~ ~r/\A[0-9a-f]{64}\z/
    end

    test "empty manifest digest is stable and non-empty" do
      assert Checksum.digest(%{}) == Checksum.digest(%{})
      assert byte_size(Checksum.digest(%{})) == 64
    end
  end

  # -- total_bytes/1 -------------------------------------------------------

  describe "total_bytes/1" do
    test "is zero for an empty manifest" do
      assert Checksum.total_bytes(%{}) == 0
    end

    test "sums sizes across all entries", %{root: root} do
      write(root, "a", "ab")
      write(root, "b", "cde")
      manifest = Checksum.manifest(root)

      assert Checksum.total_bytes(manifest) == 5
    end
  end

  # -- compare/2 -----------------------------------------------------------

  describe "compare/2" do
    test "returns :ok for two identical manifests (fast path)" do
      m = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      assert Checksum.compare(m, m) == :ok
    end

    test "returns :ok for structurally-equal-but-distinct maps" do
      a = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      b = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      assert Checksum.compare(a, b) == :ok
    end

    test "reports missing keys (present in recorded, absent in actual)" do
      recorded = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      actual = %{}

      assert {:error, {:verify_mismatch, %{missing: ["x"], extra: [], altered: []}}} =
               Checksum.compare(recorded, actual)
    end

    test "reports extra keys (absent in recorded, present in actual)" do
      recorded = %{}
      actual = %{"y" => %{"size" => 1, "sha256" => "bb"}}

      assert {:error, {:verify_mismatch, %{missing: [], extra: ["y"], altered: []}}} =
               Checksum.compare(recorded, actual)
    end

    test "reports altered keys (same key, different entry)" do
      recorded = %{"x" => %{"size" => 1, "sha256" => "aa"}}
      actual = %{"x" => %{"size" => 1, "sha256" => "ZZ"}}

      assert {:error, {:verify_mismatch, %{missing: [], extra: [], altered: ["x"]}}} =
               Checksum.compare(recorded, actual)
    end

    test "reports missing, extra and altered simultaneously" do
      recorded = %{
        "keep" => %{"size" => 1, "sha256" => "aa"},
        "gone" => %{"size" => 1, "sha256" => "bb"},
        "changed" => %{"size" => 1, "sha256" => "cc"}
      }

      actual = %{
        "keep" => %{"size" => 1, "sha256" => "aa"},
        "new" => %{"size" => 1, "sha256" => "dd"},
        "changed" => %{"size" => 2, "sha256" => "cc"}
      }

      assert {:error, {:verify_mismatch, detail}} = Checksum.compare(recorded, actual)
      assert detail.missing == ["gone"]
      assert detail.extra == ["new"]
      assert detail.altered == ["changed"]
    end

    test "detects real on-disk tampering via manifests", %{root: root} do
      write(root, "data.txt", "trusted")
      recorded = Checksum.manifest(root)

      File.write!(Path.join(root, "data.txt"), "tampered")
      actual = Checksum.manifest(root)

      assert {:error, {:verify_mismatch, %{altered: ["data.txt"]}}} =
               Checksum.compare(recorded, actual)
    end

    test "detects a deleted file via manifests", %{root: root} do
      write(root, "data.txt", "present")
      recorded = Checksum.manifest(root)

      File.rm!(Path.join(root, "data.txt"))
      actual = Checksum.manifest(root)

      assert {:error, {:verify_mismatch, %{missing: ["data.txt"], extra: [], altered: []}}} =
               Checksum.compare(recorded, actual)
    end
  end
end
