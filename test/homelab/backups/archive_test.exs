defmodule Homelab.Backups.ArchiveTest do
  use ExUnit.Case, async: true

  alias Homelab.Backups.Archive
  alias Homelab.Backups.Targets.LocalDisk

  @master_key Base.decode16!("00112233445566778899AABBCCDDEEFF00112233445566778899AABBCCDDEEFF")

  setup do
    base = Path.join(System.tmp_dir!(), "hiab-archive-#{System.unique_integer([:positive])}")
    source = Path.join(base, "source")
    root = Path.join(base, "backups")
    dest = Path.join(base, "restored")

    File.mkdir_p!(source)
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf(base) end)

    %{base: base, source: source, dest: dest, config: %{root: root}}
  end

  defp opts(extra \\ []), do: Keyword.merge([master_key: @master_key], extra)

  defp create(source, config, key, extra \\ []) do
    Archive.create(source, LocalDisk, config, key, opts(extra))
  end

  defp frame_path(config, key, index) do
    Path.join([
      config.root,
      key,
      "frames",
      index |> Integer.to_string() |> String.pad_leading(8, "0")
    ])
  end

  describe "round trip" do
    test "restores a tree byte for byte", %{source: source, dest: dest, config: config} do
      File.mkdir_p!(Path.join(source, "nested/deeper"))
      File.write!(Path.join(source, "top.txt"), "top level")
      File.write!(Path.join(source, "nested/mid.bin"), :crypto.strong_rand_bytes(4096))
      File.write!(Path.join(source, "nested/deeper/leaf.txt"), "leaf")

      assert {:ok, manifest} = create(source, config, "vol/1")
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert File.read!(Path.join(dest, "top.txt")) == "top level"
      assert File.read!(Path.join(dest, "nested/deeper/leaf.txt")) == "leaf"

      assert File.read!(Path.join(source, "nested/mid.bin")) ==
               File.read!(Path.join(dest, "nested/mid.bin"))
    end

    test "preserves file modes", %{source: source, dest: dest, config: config} do
      script = Path.join(source, "run.sh")
      File.write!(script, "#!/bin/sh\necho hi\n")
      File.chmod!(script, 0o750)

      assert {:ok, manifest} = create(source, config, "vol/modes")
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      %File.Stat{mode: mode} = File.stat!(Path.join(dest, "run.sh"))
      assert Bitwise.band(mode, 0o777) == 0o750
    end

    test "preserves symlinks as symlinks", %{source: source, dest: dest, config: config} do
      File.write!(Path.join(source, "real.txt"), "real")
      File.ln_s!("real.txt", Path.join(source, "link.txt"))

      assert {:ok, manifest} = create(source, config, "vol/links")
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert {:ok, %File.Stat{type: :symlink}} = File.lstat(Path.join(dest, "link.txt"))
      assert File.read_link!(Path.join(dest, "link.txt")) == "real.txt"
    end

    test "handles an empty directory", %{source: source, dest: dest, config: config} do
      assert {:ok, manifest} = create(source, config, "vol/empty")
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert File.dir?(dest)
    end

    test "works uncompressed", %{source: source, dest: dest, config: config} do
      File.write!(Path.join(source, "a.bin"), :crypto.strong_rand_bytes(100_000))

      assert {:ok, manifest} = create(source, config, "vol/raw", compression: :none)
      assert manifest.compression == :none
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert File.read!(Path.join(source, "a.bin")) == File.read!(Path.join(dest, "a.bin"))
    end

    test "spans many frames when the frame size is small", %{
      source: source,
      dest: dest,
      config: config
    } do
      File.write!(Path.join(source, "big.bin"), :crypto.strong_rand_bytes(300_000))

      assert {:ok, manifest} =
               create(source, config, "vol/framed", frame_size: 16_384, compression: :none)

      assert manifest.frames > 10
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())
      assert File.read!(Path.join(source, "big.bin")) == File.read!(Path.join(dest, "big.bin"))
    end
  end

  describe "manifest" do
    test "records both digests, sizes and the frame count", %{source: source, config: config} do
      File.write!(Path.join(source, "a.txt"), String.duplicate("compressible ", 5_000))

      assert {:ok, manifest} = create(source, config, "vol/meta", frame_size: 32_768)

      assert Regex.match?(~r/^[0-9a-f]{64}$/, manifest.plaintext_sha256)
      assert Regex.match?(~r/^[0-9a-f]{64}$/, manifest.archive_sha256)
      assert manifest.plaintext_sha256 != manifest.archive_sha256
      assert manifest.plaintext_bytes > 0
      assert manifest.stored_bytes > 0
      assert manifest.frames >= 1
      assert manifest.key == "vol/meta"
    end

    test "gzip actually shrinks compressible data", %{source: source, config: config} do
      File.write!(Path.join(source, "a.txt"), String.duplicate("aaaaaaaaaa", 20_000))

      assert {:ok, zipped} = create(source, config, "vol/z", compression: :gzip)
      assert {:ok, raw} = create(source, config, "vol/r", compression: :none)

      assert zipped.stored_bytes < div(raw.stored_bytes, 5)
      assert zipped.plaintext_sha256 == raw.plaintext_sha256
    end

    test "names the key that wrote it", %{source: source, config: config} do
      File.write!(Path.join(source, "a.txt"), "x")

      assert {:ok, manifest} = create(source, config, "vol/fp")

      assert manifest.key_fingerprint ==
               Homelab.Backups.Keys.fingerprint_of(@master_key)
    end

    test "a fresh data key per archive, each wrapped to its own archive id", %{
      source: source,
      config: config
    } do
      File.write!(Path.join(source, "a.txt"), "x")

      assert {:ok, first} = create(source, config, "vol/k1")
      assert {:ok, second} = create(source, config, "vol/k2")

      assert first.wrapped_data_key != second.wrapped_data_key
      assert first.id != second.id

      # The archive id is the wrap's additional data, so a wrapped key lifted from one
      # manifest cannot be pasted into another.
      assert {:error, :key_mismatch} =
               Archive.unwrap_data_key(first.wrapped_data_key, second.id, @master_key)
    end
  end

  describe "integrity" do
    setup %{source: source, config: config} do
      File.write!(Path.join(source, "payload.bin"), :crypto.strong_rand_bytes(120_000))

      {:ok, manifest} =
        create(source, config, "vol/integrity", frame_size: 16_384, compression: :none)

      assert manifest.frames > 4
      %{manifest: manifest}
    end

    test "a single flipped bit is rejected", %{
      manifest: manifest,
      config: config,
      dest: dest
    } do
      path = frame_path(config, manifest.key, 2)
      <<head::binary-40, byte, rest::binary>> = File.read!(path)
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 1), rest::binary>>)

      assert {:error, {:frame_tampered, 2}} =
               Archive.extract(manifest, LocalDisk, config, dest, opts())
    end

    test "a truncated frame is rejected", %{manifest: manifest, config: config, dest: dest} do
      path = frame_path(config, manifest.key, 1)
      contents = File.read!(path)
      File.write!(path, binary_part(contents, 0, byte_size(contents) - 64))

      assert {:error, {:frame_truncated, 1}} =
               Archive.extract(manifest, LocalDisk, config, dest, opts())
    end

    # Frames are sealed with their index as additional data, so swapping two of them
    # fails to open rather than silently producing a scrambled tree.
    test "reordered frames are rejected", %{manifest: manifest, config: config, dest: dest} do
      a = frame_path(config, manifest.key, 1)
      b = frame_path(config, manifest.key, 2)
      first = File.read!(a)
      File.write!(a, File.read!(b))
      File.write!(b, first)

      assert {:error, {:frame_out_of_order, 1, 2}} =
               Archive.extract(manifest, LocalDisk, config, dest, opts())
    end

    test "a missing frame off the end is caught by the frame count", %{
      manifest: manifest,
      config: config,
      dest: dest
    } do
      File.rm!(frame_path(config, manifest.key, manifest.frames - 1))
      expected = manifest.frames

      assert {:error, {:frame_count_mismatch, ^expected, actual}} =
               Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert actual == expected - 1
    end

    test "the wrong master key cannot open it", %{
      manifest: manifest,
      config: config,
      dest: dest
    } do
      other = :crypto.strong_rand_bytes(32)

      assert {:error, :key_mismatch} =
               Archive.extract(manifest, LocalDisk, config, dest, master_key: other)
    end

    test "a manifest claiming the wrong digest is refused", %{
      manifest: manifest,
      config: config,
      dest: dest
    } do
      tampered = %{manifest | plaintext_sha256: String.duplicate("0", 64)}

      assert {:error, {:digest_mismatch, _, _}} =
               Archive.extract(tampered, LocalDisk, config, dest, opts())
    end

    test "nothing is written to the destination when verification fails", %{
      manifest: manifest,
      config: config,
      dest: dest
    } do
      tampered = %{manifest | plaintext_sha256: String.duplicate("0", 64)}

      assert {:error, _} = Archive.extract(tampered, LocalDisk, config, dest, opts())
      refute File.exists?(dest)
    end
  end

  describe "verify_only" do
    test "streams the whole artifact and writes nothing", %{
      source: source,
      dest: dest,
      config: config
    } do
      File.write!(Path.join(source, "a.bin"), :crypto.strong_rand_bytes(50_000))
      {:ok, manifest} = create(source, config, "vol/verify", frame_size: 8_192)

      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts(verify_only: true))
      refute File.exists?(dest)
    end

    test "fails on a corrupt artifact", %{source: source, dest: dest, config: config} do
      File.write!(Path.join(source, "a.bin"), :crypto.strong_rand_bytes(50_000))
      {:ok, manifest} = create(source, config, "vol/verify2", frame_size: 8_192)

      path = frame_path(config, manifest.key, 0)
      <<head::binary-30, byte, rest::binary>> = File.read!(path)
      File.write!(path, <<head::binary, Bitwise.bxor(byte, 255), rest::binary>>)

      assert {:error, _} =
               Archive.extract(manifest, LocalDisk, config, dest, opts(verify_only: true))
    end
  end

  describe "restore over existing data" do
    test "replaces the tree only after the digest matches", %{
      source: source,
      dest: dest,
      config: config
    } do
      File.write!(Path.join(source, "new.txt"), "new contents")
      {:ok, manifest} = create(source, config, "vol/swap")

      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "old.txt"), "old contents")

      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert File.read!(Path.join(dest, "new.txt")) == "new contents"
      refute File.exists?(Path.join(dest, "old.txt"))
    end

    test "leaves existing data in place when the restore fails", %{
      source: source,
      dest: dest,
      config: config
    } do
      File.write!(Path.join(source, "new.txt"), "new contents")
      {:ok, manifest} = create(source, config, "vol/swapfail")

      File.mkdir_p!(dest)
      File.write!(Path.join(dest, "old.txt"), "old contents")

      tampered = %{manifest | plaintext_sha256: String.duplicate("0", 64)}
      assert {:error, _} = Archive.extract(tampered, LocalDisk, config, dest, opts())

      assert File.read!(Path.join(dest, "old.txt")) == "old contents"
    end
  end

  describe "failures" do
    test "a missing source is reported, not archived as empty", %{config: config} do
      assert {:error, {:source_missing, _}} =
               create("/nonexistent/path/nothing-here", config, "vol/missing")
    end

    test "a single file is archived by name", %{base: base, dest: dest, config: config} do
      file = Path.join(base, "lonely.txt")
      File.write!(file, "just me")

      assert {:ok, manifest} = create(file, config, "vol/single")
      assert :ok = Archive.extract(manifest, LocalDisk, config, dest, opts())

      assert File.read!(dest) == "just me"
    end
  end

  describe "memory" do
    # The property the 500 GB volume depends on: memory tracks the frame size, not the
    # volume size. Measured by sampling binary memory (where the payload actually
    # lives) while the archive runs, rather than reading it once afterwards, which
    # reports whatever the collector has not got to yet.
    @tag :memory
    test "binary memory tracks the frame size, not the volume size", %{
      source: source,
      config: config
    } do
      payload = 32 * 1024 * 1024
      File.write!(Path.join(source, "big.bin"), :crypto.strong_rand_bytes(payload))

      {peak, manifest} =
        with_binary_memory_sampler(fn ->
          {:ok, manifest} =
            create(source, config, "vol/mem", frame_size: 64 * 1024, compression: :none)

          manifest
        end)

      assert is_integer(peak)

      assert manifest.frames > 400

      # Observed around 1.2 MB: a frame, the pipe chunk, and slack. Anything that
      # buffers the archive instead of streaming it lands near the 32 MB payload and
      # trips this by a wide margin.
      assert peak < 4 * 1024 * 1024,
             "binary memory peaked #{div(peak, 1024)} KiB above baseline " <>
               "archiving #{div(payload, 1024)} KiB through 64 KiB frames"
    end

    # The mailbox is the other place the archive can accumulate: reading tar through
    # the port instead of a FIFO queued the whole volume as port messages.
    @tag :memory
    test "tar does not outrun the consumer into the mailbox", %{source: source, config: config} do
      File.write!(Path.join(source, "big.bin"), :crypto.strong_rand_bytes(16 * 1024 * 1024))
      owner = self()

      sampler = spawn_link(fn -> send(owner, {:queue, sample_queue(owner, 0)}) end)

      {:ok, _manifest} =
        create(source, config, "vol/mailbox", frame_size: 64 * 1024, compression: :none)

      send(sampler, :stop)

      assert_receive {:queue, peak}, 5_000
      assert peak < 32, "mailbox peaked at #{peak} messages"
    end
  end

  # Runs `fun` in its own process and samples the refc binaries THAT process holds.
  # `:erlang.memory(:binary)` is VM-wide, so with 128 async cases in flight it measures
  # the rest of the suite as much as the archive — which made this flake in a full run
  # while passing alone.
  defp with_binary_memory_sampler(fun) do
    owner = self()
    worker = spawn_link(fn -> send(owner, {:done, fun.()}) end)
    sampler = spawn_link(fn -> send(owner, {:sampled, sample_process_binaries(worker, 0)}) end)

    result =
      receive do
        {:done, result} -> result
      after
        60_000 -> flunk("archive did not finish")
      end

    send(sampler, :stop)

    receive do
      {:sampled, peak} -> {peak, result}
    after
      5_000 -> flunk("memory sampler did not report")
    end
  end

  defp sample_process_binaries(pid, peak) do
    receive do
      :stop -> peak
    after
      1 -> sample_process_binaries(pid, max(peak, process_binary_bytes(pid)))
    end
  end

  defp process_binary_bytes(pid) do
    case Process.info(pid, :binary) do
      {:binary, refs} -> Enum.reduce(refs, 0, fn {_id, size, _count}, acc -> acc + size end)
      _ -> 0
    end
  end

  defp sample_queue(pid, peak) do
    receive do
      :stop ->
        peak
    after
      1 ->
        len =
          case Process.info(pid, :message_queue_len) do
            {:message_queue_len, n} -> n
            _ -> 0
          end

        sample_queue(pid, max(peak, len))
    end
  end
end
