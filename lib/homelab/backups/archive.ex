defmodule Homelab.Backups.Archive do
  @moduledoc """
  Turns a volume into one encrypted archive, and turns it back again.

      volume -> tar -> gzip? -> frames -> AES-256-GCM -> target
                  |                          |
                  `- sha256(plaintext)       `- sha256(ciphertext)

  Every stage is a stream. Peak memory is one frame, whether the volume is 200 MB or
  500 GB, which it has to be: the app runs under a 1 GB limit and the largest volume
  here is half a terabyte.

  ## The two digests

  `plaintext_sha256` is taken over the tar bytes *before* compression and encryption.
  It is the restore-correctness proof: extract recomputes it and refuses to hand over
  a tree whose bytes are not the bytes that went in.

  `archive_sha256` is taken over the framed ciphertext. It lets a stored artifact be
  checked for rot or truncation without holding the key, which is what makes a cheap
  periodic check possible against storage that charges for reads.

  ## Frames

      frame := magic(4) | version(1) | index(u32) | length(u32) | tag(16) | ciphertext

  Each frame is sealed on its own with AES-256-GCM. The nonce is the frame index,
  which is safe because the data key is fresh for every archive and never reused. The
  additional data is `archive_id || index`, so a frame cannot be silently reordered,
  moved between archives, or spliced in from elsewhere — and a frame lost off the end
  is caught by the frame count in the manifest.

  One frame is also one S3 multipart part, so nothing downstream re-chunks.
  """

  alias Homelab.Backups.{Keys, Target}

  require Logger

  @magic "HIAB"
  @version 1
  @tag_bytes 16
  @header_bytes 13

  # 64 MiB keeps a 640 GB volume inside S3's 10,000-part ceiling while staying far
  # below the container's memory limit. `frame_size` is an option so tests can use
  # tiny frames and so a volume larger than that can scale it up.
  @default_frame_size 64 * 1024 * 1024

  # How much is pulled off the pipe at a time. The OS pipe buffer is what throttles
  # tar, so this only needs to be large enough to keep syscalls cheap.
  @pipe_chunk 256 * 1024

  @enforce_keys [:id, :key, :data_key, :frame_size, :compression]
  defstruct [:id, :key, :data_key, :frame_size, :compression]

  @type manifest :: %{
          required(:id) => String.t(),
          required(:key) => String.t(),
          required(:version) => pos_integer(),
          required(:compression) => :gzip | :none,
          required(:frame_size) => pos_integer(),
          required(:frames) => non_neg_integer(),
          required(:plaintext_bytes) => non_neg_integer(),
          required(:stored_bytes) => non_neg_integer(),
          required(:plaintext_sha256) => String.t(),
          required(:archive_sha256) => String.t(),
          required(:wrapped_data_key) => String.t(),
          required(:key_fingerprint) => String.t()
        }

  @doc """
  Archives `source_path` to `key` on `target`, returning the manifest.

  The data key is fresh per archive and is returned wrapped under the backup master
  key, so rotating the master key rewrites a few hundred bytes per artifact rather
  than re-encrypting the data.

  Options: `:frame_size`, `:compression` (`:gzip` | `:none`), `:master_key`.
  """
  @spec create(String.t(), module(), Target.config(), String.t(), keyword()) ::
          {:ok, manifest()} | {:error, term()}
  def create(source_path, target, config, key, opts \\ []) do
    if File.exists?(source_path) do
      do_create(source_path, target, config, key, opts)
    else
      {:error, {:source_missing, source_path}}
    end
  end

  defp do_create(source_path, target, config, key, opts) do
    master_key = Keyword.get_lazy(opts, :master_key, &Keys.backup_master_key/0)

    archive = %__MODULE__{
      id: generate_id(),
      key: key,
      data_key: :crypto.strong_rand_bytes(32),
      frame_size: Keyword.get(opts, :frame_size, @default_frame_size),
      compression: Keyword.get(opts, :compression, :gzip)
    }

    case target.open(config, key, opts) do
      {:ok, handle} -> write_frames(archive, source_path, target, handle, master_key)
      {:error, reason} -> {:error, {:target_unavailable, reason}}
    end
  end

  defp write_frames(archive, source_path, target, handle, master_key) do
    state = %{
      handle: handle,
      buffer: <<>>,
      index: 0,
      plaintext: :crypto.hash_init(:sha256),
      archive: :crypto.hash_init(:sha256),
      plaintext_bytes: 0,
      stored_bytes: 0,
      compressor: open_compressor(archive.compression)
    }

    try do
      with {:ok, state} <- stream_tar(source_path, archive, target, state),
           {:ok, state} <- flush_compressor(archive, target, state),
           {:ok, state} <- seal_buffer(archive, target, state, :final),
           {:ok, stored} <- target.close(state.handle) do
        {:ok, manifest(archive, state, stored, master_key)}
      else
        {:error, reason} ->
          target.abort(handle)
          {:error, reason}
      end
    rescue
      error ->
        target.abort(handle)
        {:error, {:archive_exception, Exception.message(error)}}
    after
      close_compressor(state.compressor)
    end
  end

  # -- tar --

  # GNU tar, writing into a FIFO rather than onto the port's stdout.
  #
  # Reading tar's stdout through the port looks simpler and does not work: a port has
  # no input flow control (`busy_limits_msgq` governs the output direction only), so
  # tar runs as fast as the disk allows and the entire archive piles up in the owner's
  # mailbox. Measured, that was 34 MB of mailbox for a 32 MB volume — memory tracking
  # the volume, which at 500 GB is the container's whole budget many times over.
  #
  # A FIFO pushes the problem down to the kernel, which already solves it: the pipe
  # buffer fills and tar blocks in `write` until this catches up. The port stays, but
  # only to carry the exit status. Exit 1 is tar's "some files differ" (something
  # changed while being read) and exit 2 is fatal; both are surfaced rather than folded
  # into success, because a partial archive reporting success is the failure this
  # feature exists to prevent.
  defp stream_tar(source_path, archive, target, state) do
    {parent, entry} = split_source(source_path)
    scratch = Path.join(System.tmp_dir!(), "hiab-tar-#{archive.id}")
    fifo_path = scratch <> ".fifo"
    err_path = scratch <> ".err"

    try do
      with :ok <- make_fifo(fifo_path) do
        command =
          "exec tar -cf - -C #{shell_quote(parent)} #{shell_quote(entry)} " <>
            "> #{shell_quote(fifo_path)} 2> #{shell_quote(err_path)}"

        port =
          Port.open({:spawn_executable, sh()}, [
            :binary,
            :exit_status,
            :use_stdio,
            :stream,
            args: ["-c", command]
          ])

        # Both ends block until the other arrives, so this rendezvous with the
        # redirection the shell performs before it execs tar.
        case :file.open(fifo_path, [:read, :binary, :raw]) do
          {:ok, io} ->
            try do
              drain_fifo(io, port, archive, target, state, err_path)
            after
              :file.close(io)
            end

          {:error, reason} ->
            close_port(port)
            {:error, {:fifo_unreadable, reason}}
        end
      end
    after
      File.rm(fifo_path)
      File.rm(err_path)
    end
  end

  defp make_fifo(path) do
    File.rm(path)

    case System.cmd("mkfifo", [path], stderr_to_stdout: true) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:mkfifo_failed, status, String.trim(out)}}
    end
  rescue
    ErlangError -> {:error, {:mkfifo_failed, :enoent, "mkfifo is not installed"}}
  end

  defp drain_fifo(io, port, archive, target, state, err_path) do
    case :file.read(io, @pipe_chunk) do
      {:ok, chunk} ->
        case absorb(chunk, archive, target, state) do
          {:ok, state} ->
            drain_fifo(io, port, archive, target, state, err_path)

          {:error, reason} ->
            close_port(port)
            {:error, reason}
        end

      :eof ->
        await_tar(port, state, err_path)

      {:error, reason} ->
        close_port(port)
        {:error, {:pipe_read_failed, reason}}
    end
  end

  defp await_tar(port, state, err_path) do
    receive do
      {^port, {:exit_status, 0}} ->
        {:ok, state}

      {^port, {:exit_status, status}} ->
        {:error, {:tar_failed, status, read_stderr(err_path)}}
    after
      30_000 ->
        close_port(port)
        {:error, {:tar_failed, :no_exit_status, read_stderr(err_path)}}
    end
  end

  defp close_port(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp read_stderr(path) do
    case File.read(path) do
      {:ok, contents} -> contents |> String.trim() |> String.slice(0, 2_000)
      {:error, _} -> ""
    end
  end

  # A single file is archived by name from its own directory; a directory is archived
  # as itself, so extracting reproduces the tree rather than scattering its contents.
  defp split_source(source_path) do
    trimmed = Path.absname(source_path)
    {Path.dirname(trimmed), Path.basename(trimmed)}
  end

  defp sh, do: System.find_executable("sh") || "/bin/sh"

  defp shell_quote(value), do: "'" <> String.replace(value, "'", "'\\''") <> "'"

  # -- framing --

  defp absorb(chunk, archive, target, state) do
    state = %{
      state
      | plaintext: :crypto.hash_update(state.plaintext, chunk),
        plaintext_bytes: state.plaintext_bytes + byte_size(chunk)
    }

    compressed = compress(state.compressor, chunk)
    buffer = state.buffer <> compressed

    seal_buffer(archive, target, %{state | buffer: buffer}, :while_full)
  end

  # `:while_full` emits only whole frames, so every frame but the last is exactly
  # `frame_size`. `:final` emits whatever is left, including nothing at all for an
  # empty source — an archive with zero frames is still a valid archive.
  defp seal_buffer(archive, target, state, mode) do
    cond do
      byte_size(state.buffer) >= archive.frame_size ->
        <<plain::binary-size(archive.frame_size), rest::binary>> = state.buffer

        # `rest` is a sub-binary of the buffer, and a sub-binary keeps its whole parent
        # alive. Carrying it forward retains every buffer this archive ever built, so
        # memory tracked the volume rather than the frame. Copying it frees the parent.
        rest = :binary.copy(rest)

        case emit(archive, target, state, plain) do
          {:ok, state} -> seal_buffer(archive, target, %{state | buffer: rest}, mode)
          {:error, reason} -> {:error, reason}
        end

      mode == :final and state.buffer != <<>> ->
        case emit(archive, target, state, state.buffer) do
          {:ok, state} -> {:ok, %{state | buffer: <<>>}}
          {:error, reason} -> {:error, reason}
        end

      true ->
        {:ok, state}
    end
  end

  defp emit(archive, target, state, plain) do
    frame = seal(archive, state.index, plain)

    case target.write(state.handle, frame) do
      {:ok, handle} ->
        # Frames are refc binaries, freed only when this process collects. Sealing and
        # writing allocates almost nothing on the process heap, so nothing prompts a
        # collection and every frame stays resident — 41 MB for a 32 MB volume when
        # measured. One collection per frame is negligible beside encrypting 64 MiB.
        :erlang.garbage_collect()

        {:ok,
         %{
           state
           | handle: handle,
             index: state.index + 1,
             archive: :crypto.hash_update(state.archive, frame),
             stored_bytes: state.stored_bytes + byte_size(frame)
         }}

      {:error, reason} ->
        {:error, {:target_write_failed, reason}}
    end
  end

  defp seal(archive, index, plain) do
    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        archive.data_key,
        nonce(index),
        plain,
        aad(archive.id, index),
        true
      )

    header(index, byte_size(plain))
    |> Kernel.<>(tag)
    |> Kernel.<>(ciphertext)
  end

  defp header(index, length),
    do: <<@magic, @version::8, index::unsigned-big-32, length::unsigned-big-32>>

  defp nonce(index), do: <<0::size(64), index::unsigned-big-32>>

  defp aad(id, index), do: id <> <<index::unsigned-big-32>>

  # -- compression --

  # windowBits 31 is deflate's 15 plus 16, which asks zlib for a gzip wrapper, so the
  # payload under the encryption is an ordinary .tar.gz.
  defp open_compressor(:none), do: nil

  defp open_compressor(:gzip) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 1, :deflated, 31, 8, :default)
    z
  end

  defp compress(nil, chunk), do: chunk
  defp compress(z, chunk), do: z |> :zlib.deflate(chunk) |> IO.iodata_to_binary()

  defp flush_compressor(_archive, _target, %{compressor: nil} = state), do: {:ok, state}

  defp flush_compressor(archive, target, state) do
    tail = state.compressor |> :zlib.deflate(<<>>, :finish) |> IO.iodata_to_binary()
    seal_buffer(archive, target, %{state | buffer: state.buffer <> tail}, :while_full)
  end

  defp close_compressor(nil), do: :ok

  defp close_compressor(z) do
    :zlib.deflateEnd(z)
    :zlib.close(z)
    :ok
  rescue
    ErlangError -> :ok
  end

  # -- manifest --

  defp manifest(archive, state, stored, master_key) do
    %{
      id: archive.id,
      key: archive.key,
      version: @version,
      compression: archive.compression,
      frame_size: archive.frame_size,
      frames: state.index,
      plaintext_bytes: state.plaintext_bytes,
      stored_bytes: state.stored_bytes,
      plaintext_sha256: finish_hash(state.plaintext),
      archive_sha256: finish_hash(state.archive),
      wrapped_data_key: wrap_data_key(archive, master_key),
      key_fingerprint: Keys.fingerprint_of(master_key),
      target_metadata: stored
    }
  end

  defp finish_hash(state), do: state |> :crypto.hash_final() |> Base.encode16(case: :lower)

  # The data key is wrapped under the master key with the archive id as additional
  # data, so a wrapped key lifted from one manifest cannot be pasted into another.
  defp wrap_data_key(archive, master_key) do
    iv = :crypto.strong_rand_bytes(12)

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(
        :aes_256_gcm,
        master_key,
        iv,
        archive.data_key,
        archive.id,
        true
      )

    Base.encode64(iv <> tag <> ciphertext)
  end

  @doc false
  @spec unwrap_data_key(String.t(), String.t(), binary()) ::
          {:ok, binary()} | {:error, :key_mismatch | :malformed}
  def unwrap_data_key(wrapped, archive_id, master_key) do
    with {:ok, decoded} <- Base.decode64(wrapped),
         <<iv::binary-12, tag::binary-16, ciphertext::binary>> <- decoded do
      case :crypto.crypto_one_time_aead(
             :aes_256_gcm,
             master_key,
             iv,
             ciphertext,
             archive_id,
             tag,
             false
           ) do
        key when is_binary(key) -> {:ok, key}
        :error -> {:error, :key_mismatch}
      end
    else
      _ -> {:error, :malformed}
    end
  end

  defp generate_id, do: 16 |> :crypto.strong_rand_bytes() |> Base.encode16(case: :lower)

  # -- reading back --

  @doc """
  Extracts the archive described by `manifest` into `dest`.

  Restores through a staging directory and moves it into place only once the
  plaintext digest matches, so a failed or tampered restore never leaves partial
  bytes where the application expects its data. Returns `{:error, :digest_mismatch}`
  rather than a tree that is not what was backed up.

  Pass `verify_only: true` to stream the whole artifact, check everything, and write
  nothing — the deep verification the Backups page reports.
  """
  @spec extract(manifest(), module(), Target.config(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def extract(manifest, target, config, dest, opts \\ []) do
    master_key = Keyword.get_lazy(opts, :master_key, &Keys.backup_master_key/0)
    verify_only? = Keyword.get(opts, :verify_only, false)
    id = fetch(manifest, :id)

    with {:ok, data_key} <- unwrap_data_key(fetch(manifest, :wrapped_data_key), id, master_key),
         {:ok, stream} <- open_read(target, config, fetch(manifest, :key), opts) do
      run_extract(manifest, stream, data_key, dest, verify_only?)
    end
  end

  defp open_read(target, config, key, opts) do
    case target.read_stream(config, key, opts) do
      {:ok, stream} -> {:ok, stream}
      {:error, reason} -> {:error, {:target_unavailable, reason}}
    end
  end

  defp run_extract(manifest, stream, data_key, dest, verify_only?) do
    id = fetch(manifest, :id)
    compression = manifest |> fetch(:compression) |> normalize_compression()

    staging =
      Path.join(
        System.tmp_dir!(),
        "hiab-restore-#{id}-#{System.unique_integer([:positive])}"
      )

    try do
      with :ok <- File.mkdir_p(staging),
           {:ok, tar_path, digest, frames} <-
             rebuild(stream, id, data_key, compression, staging),
           # Frames first: a missing frame off the end also fails the digest, and
           # "the artifact is short" is a more useful answer than "the bytes differ".
           :ok <- check_frames(frames, fetch(manifest, :frames)),
           :ok <- check_digest(digest, fetch(manifest, :plaintext_sha256)) do
        if verify_only? do
          :ok
        else
          unpack_and_swap(tar_path, staging, dest)
        end
      end
    after
      File.rm_rf(staging)
    end
  end

  defp rebuild(stream, id, data_key, compression, staging) do
    tar_path = Path.join(staging, "archive.tar")

    case File.open(tar_path, [:write, :binary, :raw]) do
      {:ok, io} ->
        z = open_decompressor(compression)

        try do
          fold_frames(stream, io, id, data_key, z, tar_path)
        after
          File.close(io)
          close_decompressor(z)
        end

      {:error, reason} ->
        {:error, {:staging_unwritable, reason}}
    end
  end

  defp fold_frames(stream, io, id, data_key, z, tar_path) do
    initial = {:ok, :crypto.hash_init(:sha256), 0}

    result =
      Enum.reduce_while(stream, initial, fn frame, {:ok, hash, index} ->
        case open_frame(frame, id, data_key, index) do
          {:ok, plain} ->
            plain = decompress(z, plain)
            :ok = IO.binwrite(io, plain)
            {:cont, {:ok, :crypto.hash_update(hash, plain), index + 1}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)

    case result do
      {:ok, hash, frames} ->
        tail = flush_decompressor(z)
        :ok = IO.binwrite(io, tail)
        hash = :crypto.hash_update(hash, tail)
        {:ok, tar_path, Base.encode16(:crypto.hash_final(hash), case: :lower), frames}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # A frame is rejected for the wrong index as firmly as for a bad tag: the index is
  # in the additional data, so a reordered or spliced frame fails to open at all.
  defp open_frame(frame, id, data_key, expected_index) do
    case frame do
      <<@magic, @version::8, index::unsigned-big-32, length::unsigned-big-32,
        tag::binary-size(@tag_bytes), ciphertext::binary>> ->
        cond do
          index != expected_index ->
            {:error, {:frame_out_of_order, expected_index, index}}

          byte_size(ciphertext) != length ->
            {:error, {:frame_truncated, index}}

          true ->
            decrypt_frame(id, data_key, index, ciphertext, tag)
        end

      _ ->
        {:error, {:frame_malformed, expected_index}}
    end
  end

  defp decrypt_frame(id, data_key, index, ciphertext, tag) do
    case :crypto.crypto_one_time_aead(
           :aes_256_gcm,
           data_key,
           nonce(index),
           ciphertext,
           aad(id, index),
           tag,
           false
         ) do
      plain when is_binary(plain) -> {:ok, plain}
      :error -> {:error, {:frame_tampered, index}}
    end
  end

  defp check_digest(actual, expected) when actual == expected, do: :ok
  defp check_digest(actual, expected), do: {:error, {:digest_mismatch, expected, actual}}

  defp check_frames(actual, expected) when actual == expected, do: :ok
  defp check_frames(actual, expected), do: {:error, {:frame_count_mismatch, expected, actual}}

  # The tree is assembled beside the destination and moved in only after the digest
  # has matched, so a restore never streams bytes over live data.
  defp unpack_and_swap(tar_path, staging, dest) do
    unpacked = Path.join(staging, "tree")

    with :ok <- File.mkdir_p(unpacked),
         :ok <- run_untar(tar_path, unpacked),
         {:ok, [entry]} <- File.ls(unpacked),
         :ok <- File.mkdir_p(Path.dirname(dest)),
         :ok <- replace(Path.join(unpacked, entry), dest) do
      :ok
    else
      {:ok, entries} -> {:error, {:unexpected_archive_root, entries}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp run_untar(tar_path, dest) do
    case System.cmd(sh(), [
           "-c",
           "exec tar -xf #{shell_quote(tar_path)} -C #{shell_quote(dest)} 2>&1"
         ]) do
      {_out, 0} -> :ok
      {out, status} -> {:error, {:untar_failed, status, String.slice(out, 0, 2_000)}}
    end
  end

  # `File.rename/2` is atomic within a filesystem but fails across devices, which is
  # exactly what happens when staging is on tmpfs and the destination is on disk.
  defp replace(from, dest) do
    previous = dest <> ".replaced-#{System.unique_integer([:positive])}"
    existed? = File.exists?(dest)

    with :ok <- if(existed?, do: File.rename(dest, previous), else: :ok),
         :ok <- move(from, dest) do
      if existed?, do: File.rm_rf(previous)
      :ok
    else
      {:error, reason} ->
        if existed? and not File.exists?(dest), do: File.rename(previous, dest)
        {:error, {:swap_failed, reason}}
    end
  end

  defp move(from, dest) do
    case File.rename(from, dest) do
      :ok ->
        :ok

      {:error, :exdev} ->
        with {:ok, _} <- File.cp_r(from, dest), do: :ok

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp open_decompressor(:none), do: nil

  defp open_decompressor(:gzip) do
    z = :zlib.open()
    :ok = :zlib.inflateInit(z, 31)
    z
  end

  defp decompress(nil, chunk), do: chunk
  defp decompress(z, chunk), do: z |> :zlib.inflate(chunk) |> IO.iodata_to_binary()

  defp flush_decompressor(nil), do: <<>>
  defp flush_decompressor(_z), do: <<>>

  defp close_decompressor(nil), do: :ok

  defp close_decompressor(z) do
    :zlib.inflateEnd(z)
    :zlib.close(z)
    :ok
  rescue
    ErlangError -> :ok
  end

  defp normalize_compression(value) when value in [:gzip, :none], do: value
  defp normalize_compression("gzip"), do: :gzip
  defp normalize_compression("none"), do: :none

  # Manifests come back from JSON with string keys, and from `create/5` with atoms.
  defp fetch(manifest, key) do
    case Map.fetch(manifest, key) do
      {:ok, value} -> value
      :error -> Map.fetch!(manifest, Atom.to_string(key))
    end
  end

  @doc "Bytes of framing overhead per frame, for sizing and for tests."
  def frame_overhead, do: @header_bytes + @tag_bytes

  @doc "The default frame size, also the default S3 part size."
  def default_frame_size, do: @default_frame_size
end
