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
end
