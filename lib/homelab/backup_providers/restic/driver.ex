defmodule Homelab.BackupProviders.Restic.Driver do
  @moduledoc """
  Low-level driver behaviour for the `restic` CLI binary.

  This abstraction is independent of `BackupProviderV2`'s tier shape — it
  is concerned only with "how do I talk to restic?". Both `ResticLan`
  (Tier 1) and `ResticOffsite` (Tier 3) compose this driver with their
  tier-specific repo URLs, password sources, and schedule policies.

  Implementations:

    * `Homelab.BackupProviders.Restic.Driver.Cli` — production; shells out
      to the host `restic` binary.
    * `Homelab.BackupProviders.Restic.Driver.Fake` — tests; in-process
      state tracking init/backup/snapshot/forget/restore calls.

  For one-shot expectations prefer `Homelab.Mocks.Restic.Driver` (Mox).
  """

  @type repo_url :: String.t()
  @type snapshot_id :: String.t()
  @type password_ref :: {:vault, String.t()} | {:plaintext, String.t()}

  @type snapshot :: %{
          id: String.t(),
          short_id: String.t(),
          time: DateTime.t(),
          hostname: String.t() | nil,
          tags: [String.t()],
          paths: [String.t()],
          tree: String.t() | nil
        }

  @type backup_result :: %{
          snapshot_id: snapshot_id(),
          files_new: non_neg_integer(),
          files_changed: non_neg_integer(),
          files_unmodified: non_neg_integer(),
          bytes_added: non_neg_integer(),
          total_bytes: non_neg_integer()
        }

  @type retention :: %{
          optional(:keep_last) => pos_integer(),
          optional(:keep_hourly) => pos_integer(),
          optional(:keep_daily) => pos_integer(),
          optional(:keep_weekly) => pos_integer(),
          optional(:keep_monthly) => pos_integer(),
          optional(:keep_yearly) => pos_integer(),
          optional(:keep_tag) => [String.t()]
        }

  @callback init_repo(repo_url(), password_ref(), env :: map()) :: :ok | {:error, term()}

  @callback backup(
              repo_url(),
              password_ref(),
              paths :: [String.t()],
              tags :: [String.t()],
              env :: map()
            ) :: {:ok, backup_result()} | {:error, term()}

  @callback list_snapshots(repo_url(), password_ref(), filter :: keyword(), env :: map()) ::
              {:ok, [snapshot()]} | {:error, term()}

  @callback restore(
              repo_url(),
              password_ref(),
              snapshot_id(),
              target_path :: String.t(),
              env :: map()
            ) :: :ok | {:error, term()}

  @callback forget(repo_url(), password_ref(), retention(), env :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback check(repo_url(), password_ref(), env :: map()) :: :ok | {:error, term()}

  @spec impl() :: module()
  def impl,
    do:
      Application.get_env(
        :homelab,
        :restic_driver,
        Homelab.BackupProviders.Restic.Driver.Cli
      )
end
