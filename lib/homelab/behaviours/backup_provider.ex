defmodule Homelab.Behaviours.BackupProvider do
  @moduledoc """
  Behaviour for backup storage providers.

  Implementations manage backup creation, restoration, and retention
  for tools like Restic, Borg, etc.
  """

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()

  @callback backup(source_path :: String.t(), repo :: String.t(), tags :: [String.t()]) ::
              {:ok, snapshot_id :: String.t()} | {:error, term()}
  @callback restore(snapshot_id :: String.t(), target_path :: String.t()) ::
              :ok | {:error, term()}
  @callback list_snapshots(repo :: String.t()) :: {:ok, [map()]} | {:error, term()}
  @callback prune(repo :: String.t(), policy :: map()) :: {:ok, map()} | {:error, term()}

  @doc """
  The repository this provider reads and writes.

  Optional: `list_snapshots/1` and `prune/2` both take a repo, and a caller that
  only holds the provider module has no other way to name the one it uses. A
  provider that cannot answer simply does not export this, and listing the
  repository reports that rather than guessing a path.
  """
  @callback repo() :: String.t()

  @optional_callbacks repo: 0
end
