defmodule Homelab.Backups.Keys do
  @moduledoc """
  The operator's Recovery Key, and the subkeys backups derive from it.

  One secret is escrowed. Everything else is derived from it with HKDF, so the
  operator keeps a single string in a password manager and can rebuild an instance
  from nothing but that string and the bundle's location:

      Recovery Key
        |- HKDF("hiab:bundle:v1") -> encrypts the instance bundle
        `- HKDF("hiab:backup:v1") -> wraps each backup's own data key

  Deliberately not keyed off `secret_key_base`. That key encrypts system settings
  and deployment secrets, so a shared root would mean losing it costs every backup
  as well, and escrowing it would hand out the key to every stored credential. The
  Recovery Key is independent, and `secret_key_base` travels *inside* the bundle
  this key protects.

  Nothing here falls back. A key that can be neither read nor persisted raises, as
  `Homelab.Deployments.PermanentHome.managed_root/0` does, so the refusal lands
  before anything writes a backup nobody can read.
  """

  alias Homelab.Settings

  @key_bytes 32
  @key_file "recovery_key"
  @escrow_setting "backup_recovery_key_escrowed"

  @bundle_info "hiab:bundle:v1"
  @backup_info "hiab:backup:v1"
  @fingerprint_info "hiab:fingerprint:v1"

  # Base32's alphabet is A-Z and 2-7, so a transcribed key has no 0/O or 1/I to
  # confuse. 32 bytes encode to 52 characters; 4 more carry the checksum.
  @encoded_length 52
  @checksum_length 4
  @group 4

  @doc """
  The Recovery Key, generating and persisting one on first call.

  Raises when the key cannot be persisted: an unpersisted key encrypts backups
  that nobody will be able to read after the next restart.
  """
  @spec ensure!() :: binary()
  def ensure! do
    case read() do
      {:ok, key} ->
        key

      {:error, :absent} ->
        key = :crypto.strong_rand_bytes(@key_bytes)
        :ok = write!(key)
        key
    end
  end

  @doc "The Recovery Key if one has been provisioned, without creating one."
  @spec read() :: {:ok, binary()} | {:error, :absent}
  def read do
    with {:ok, contents} <- File.read(key_path()),
         {:ok, key} <- parse(contents) do
      {:ok, key}
    else
      _ -> {:error, :absent}
    end
  end

  @doc "True once a Recovery Key exists on disk."
  @spec provisioned?() :: boolean()
  def provisioned?, do: match?({:ok, _}, read())

  @doc "The key the instance bundle is encrypted under."
  @spec bundle_key() :: binary()
  def bundle_key, do: bundle_key(ensure!())

  @doc """
  The bundle key for a Recovery Key held in hand rather than on disk.

  Restoring onto new hardware derives from a key the operator has just typed,
  before there is anything on disk to read one from.
  """
  @spec bundle_key(binary()) :: binary()
  def bundle_key(recovery_key) when byte_size(recovery_key) == @key_bytes,
    do: derive(recovery_key, @bundle_info)

  @doc "The key each backup's own data key is wrapped under."
  @spec backup_master_key() :: binary()
  def backup_master_key, do: backup_master_key(ensure!())

  @doc "The backup master key for a Recovery Key held in hand rather than on disk."
  @spec backup_master_key(binary()) :: binary()
  def backup_master_key(recovery_key) when byte_size(recovery_key) == @key_bytes,
    do: derive(recovery_key, @backup_info)

  @doc """
  A stable public identifier for the current key, recorded in every manifest.

  Lets the Backups page say an artifact was written under a key this instance no
  longer holds, at list time rather than part-way through a restore.
  """
  @spec fingerprint() :: String.t()
  def fingerprint, do: fingerprint_of(ensure!())

  @doc "The fingerprint of an arbitrary key, for checking a manifest against it."
  @spec fingerprint_of(binary()) :: String.t()
  def fingerprint_of(key) when byte_size(key) == @key_bytes do
    key
    |> derive(@fingerprint_info)
    |> binary_part(0, 8)
    |> Base.encode16(case: :lower)
  end

  @doc """
  The Recovery Key as the operator sees it: groups of four, checksummed.

  The checksum catches a transcription slip at the point it is typed, rather than
  as an undecryptable bundle during a recovery.
  """
  @spec format(binary()) :: String.t()
  def format(key) when byte_size(key) == @key_bytes do
    encoded = Base.encode32(key, padding: false)

    (encoded <> checksum(encoded))
    |> String.to_charlist()
    |> Enum.chunk_every(@group)
    |> Enum.map_join("-", &to_string/1)
  end

  @doc """
  Parses a key the operator typed back in, tolerating case, spaces and dashes.

  Returns `{:error, :checksum}` for a key that decodes but fails its checksum,
  which is the common case of one mistyped character and is worth saying plainly.
  """
  @spec parse(String.t()) :: {:ok, binary()} | {:error, :malformed | :checksum}
  def parse(input) when is_binary(input) do
    normalized = input |> String.upcase() |> String.replace(~r/[^A-Z2-7]/, "")

    if String.length(normalized) == @encoded_length + @checksum_length do
      {encoded, given} = String.split_at(normalized, @encoded_length)

      if Plug.Crypto.secure_compare(checksum(encoded), given) do
        decode(encoded)
      else
        {:error, :checksum}
      end
    else
      {:error, :malformed}
    end
  end

  def parse(_), do: {:error, :malformed}

  @doc "True once the operator has confirmed they stored the key off this machine."
  @spec escrowed?() :: boolean()
  def escrowed?, do: Settings.get(@escrow_setting) == "true"

  @doc "Records the operator's confirmation that the key is stored off this machine."
  @spec mark_escrowed() :: :ok
  def mark_escrowed do
    Settings.set(@escrow_setting, "true", category: "backups")
    :ok
  end

  @doc "Where the key is persisted. Honours HOMELAB_SECRETS_DIR like `runtime.exs`."
  @spec key_path() :: String.t()
  def key_path, do: Path.join(secrets_dir(), @key_file)

  # -- internals --

  # HKDF-Expand (RFC 5869). The Recovery Key is already 32 uniformly random bytes,
  # so it serves as the pseudorandom key directly and no extract step is needed.
  # One round suffices because the output is exactly one hash length.
  defp derive(key, info) do
    :crypto.mac(:hmac, :sha256, key, info <> <<1>>)
  end

  defp decode(encoded) do
    case Base.decode32(encoded, padding: false) do
      {:ok, key} when byte_size(key) == @key_bytes -> {:ok, key}
      _ -> {:error, :malformed}
    end
  end

  defp checksum(encoded) do
    :sha256
    |> :crypto.hash(encoded)
    |> Base.encode32(padding: false)
    |> binary_part(0, @checksum_length)
  end

  defp write!(key) do
    path = key_path()
    dir = Path.dirname(path)

    with :ok <- File.mkdir_p(dir),
         :ok <- File.write(path, format(key)),
         :ok <- File.chmod(path, 0o600) do
      :ok
    else
      {:error, reason} ->
        raise """
        Could not persist the backup Recovery Key to #{path} (#{:file.format_error(reason)}).

        Every backup and the instance bundle are encrypted under this key, and a key
        that is not persisted is gone at the next restart, taking every backup written
        under it with it. Mount the homelab-iab-secrets volume at #{dir}, or set
        HOMELAB_SECRETS_DIR to a durable directory, and start again.
        """
    end
  end

  defp secrets_dir, do: System.get_env("HOMELAB_SECRETS_DIR", "/run/secrets")
end
