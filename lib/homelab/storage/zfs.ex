defmodule Homelab.Storage.Zfs do
  @moduledoc """
  Behaviour for ZFS pool, dataset, snapshot, and encryption operations.

  All ZFS work is performed through a single host-side privileged agent
  (`homelab-zfs-agent`) reachable over a Unix socket at
  `/run/homelab/zfs.sock`. The BEAM never invokes `zfs`/`zpool` directly —
  the agent is the single serialization point per pool, eliminating
  races between Snapshotter, RestoreDrill, Verifier, Importer, and Builder.

  CLI invocations on the agent side always use `-H -p` so output parsing is
  stable across locales. The agent declares a `protocol_version`; the
  default implementation here refuses to talk to an incompatible version.

  Two implementations ship:

    * `Homelab.Storage.Zfs.HostAgent` — production; talks to the Unix-socket agent.
    * `Homelab.Storage.Zfs.InMemory` — tests; ETS-backed fake that maintains
      pool/dataset/snapshot/clone state across calls in a single test.

  Tests that only care about a single call sequence prefer Mox via
  `Homelab.Mocks.Storage.Zfs` (defined in `test/support/mocks.ex`).
  """

  @typedoc "Fully-qualified dataset or snapshot name, e.g. `tank/appdata/foo` or `tank/appdata/foo@v1`."
  @type dataset :: String.t()
  @type snapshot :: String.t()
  @type pool :: String.t()

  @typedoc """
  Inclusive options for `create_pool/3`. Defaults align with the pinned
  pool/dataset options in the architecture plan (decision §3): ashift=12,
  compression=zstd, atime=off, xattr=sa, acltype=posixacl, dnodesize=auto,
  recordsize=128K, encryption=aes-256-gcm, keyformat=raw, keylocation=file://...
  """
  @type pool_opts :: %{
          optional(:ashift) => pos_integer(),
          optional(:compression) => String.t(),
          optional(:atime) => :on | :off,
          optional(:xattr) => :sa | :on | :off,
          optional(:acltype) => :posixacl | :off,
          optional(:dnodesize) => :auto | :legacy,
          optional(:recordsize) => String.t(),
          optional(:encryption) => String.t() | :off,
          optional(:keyformat) => :raw | :hex | :passphrase,
          optional(:keylocation) => String.t(),
          optional(:force) => boolean()
        }

  @type dataset_opts :: %{
          optional(:recordsize) => String.t(),
          optional(:compression) => String.t(),
          optional(:quota) => String.t(),
          optional(:mountpoint) => String.t() | :none,
          optional(:canmount) => :on | :off | :noauto,
          optional(:encryption) => String.t() | :inherit
        }

  @type pool_info :: %{
          name: String.t(),
          health: :online | :degraded | :faulted | :offline | :removed | :unavail | :unknown,
          size_bytes: non_neg_integer(),
          allocated_bytes: non_neg_integer(),
          free_bytes: non_neg_integer(),
          last_scrub_at: DateTime.t() | nil
        }

  @type dataset_info :: %{
          name: String.t(),
          type: :filesystem | :volume,
          mountpoint: String.t() | :none,
          used_bytes: non_neg_integer(),
          available_bytes: non_neg_integer(),
          referenced_bytes: non_neg_integer(),
          encrypted?: boolean(),
          key_loaded?: boolean()
        }

  @type snapshot_info :: %{
          name: String.t(),
          dataset: String.t(),
          created_at: DateTime.t(),
          used_bytes: non_neg_integer(),
          referenced_bytes: non_neg_integer()
        }

  @typedoc """
  Stream returned from `send_stream/3`. Callers consume it like any
  `Enumerable`. Each element is a binary chunk of the `zfs send` output.
  """
  @type send_stream :: Enumerable.t()

  @callback protocol_version() :: {:ok, pos_integer()} | {:error, term()}

  # --- Pool ---
  @callback list_pools() :: {:ok, [pool_info()]} | {:error, term()}
  @callback create_pool(pool(), vdev :: [String.t()], pool_opts()) ::
              :ok | {:error, term()}
  @callback import_pool(pool(), opts :: keyword()) :: :ok | {:error, term()}
  @callback export_pool(pool()) :: :ok | {:error, term()}
  @callback pool_status(pool()) :: {:ok, pool_info()} | {:error, term()}
  @callback scrub_pool(pool()) :: :ok | {:error, term()}

  # --- Dataset ---
  @callback dataset_exists?(dataset()) :: boolean()
  @callback create_dataset(dataset(), dataset_opts()) :: :ok | {:error, term()}
  @callback destroy_dataset(dataset(), opts :: keyword()) :: :ok | {:error, term()}
  @callback list_datasets(parent :: dataset() | nil) ::
              {:ok, [dataset_info()]} | {:error, term()}
  @callback get_property(dataset(), property :: String.t()) ::
              {:ok, String.t()} | {:error, term()}
  @callback set_property(dataset(), property :: String.t(), value :: String.t()) ::
              :ok | {:error, term()}

  # --- Snapshot ---
  @callback snapshot(dataset(), snap_name :: String.t()) ::
              {:ok, snapshot()} | {:error, term()}
  @callback destroy_snapshot(snapshot()) :: :ok | {:error, term()}
  @callback list_snapshots(dataset()) :: {:ok, [snapshot_info()]} | {:error, term()}
  @callback clone(snapshot(), target :: dataset(), dataset_opts()) :: :ok | {:error, term()}
  @callback rollback(snapshot()) :: :ok | {:error, term()}

  # --- Send/Recv ---

  @doc """
  Returns a stream of `zfs send` output. `opts` may include:

    * `:incremental_from` — base snapshot for `-i` / `-I` send
    * `:raw` — `true` to use `-w` (raw, encrypted-blocks-preserved send, used
      for Tier-2 replication so the replica never holds plaintext)
    * `:large_block` — `true` to pass `-L`
    * `:compressed` — `true` to pass `-c`
  """
  @callback send_stream(snapshot(), opts :: keyword()) ::
              {:ok, send_stream()} | {:error, term()}

  @doc """
  Consumes a `zfs recv` stream into a target dataset. The stream is an
  `Enumerable` of binary chunks produced by `send_stream/2` or read off
  the network from a remote replication source.
  """
  @callback receive_stream(target :: dataset(), Enumerable.t(), opts :: keyword()) ::
              :ok | {:error, term()}

  # --- Encryption ---
  @callback load_key(dataset(), opts :: keyword()) :: :ok | {:error, term()}
  @callback unload_key(dataset()) :: :ok | {:error, term()}
  @callback change_key(dataset(), opts :: keyword()) :: :ok | {:error, term()}

  # --- Mount ---
  @callback mount(dataset()) :: :ok | {:error, term()}
  @callback unmount(dataset()) :: :ok | {:error, term()}

  @doc """
  Returns the currently configured Zfs implementation module. Resolved
  from `Application.get_env(:homelab, :zfs_impl, ...)` so tests can swap
  in `Homelab.Mocks.Storage.Zfs` or `Homelab.Storage.Zfs.InMemory`.
  """
  @spec impl() :: module()
  def impl, do: Application.get_env(:homelab, :zfs_impl, Homelab.Storage.Zfs.HostAgent)
end
