defmodule Homelab.Behaviours.BackupProviderV2 do
  @moduledoc """
  Multi-tier backup provider behaviour (decision §5).

  Each tier has its own module (`ZfsSnapshot`, `ResticLan`, `ZfsReplicate`,
  `ResticOffsite`). Scheduling is driven by `backup_schedules` rows; execution
  creates `backup_jobs` tagged with `tier` and `target_ref`.
  """

  @type tier :: :local_snapshot | :restic_lan | :zfs_replicate | :restic_offsite

  @type target_spec ::
          {:dataset, String.t()}
          | {:restic_repo, String.t(), {:vault_ref, String.t()}}
          | {:replication_target, String.t(), String.t()}
          | {:bind_mount_path, String.t()}

  @type capture_handle :: %{
          required(:provider) => module(),
          required(:tier) => tier(),
          required(:id) => String.t(),
          required(:created_at) => DateTime.t(),
          optional(:metadata) => map()
        }

  @callback driver_id() :: String.t()
  @callback display_name() :: String.t()
  @callback description() :: String.t()
  @callback tier() :: tier()

  @callback capture(target_spec(), opts :: map()) ::
              {:ok, capture_handle()} | {:error, term()}

  @callback verify(capture_handle()) :: {:ok, map()} | {:error, term()}

  @callback restore(capture_handle(), into :: target_spec(), opts :: map()) ::
              {:ok, map()} | {:error, term()}

  @callback list(filter :: map()) :: {:ok, [capture_handle()]} | {:error, term()}

  @callback prune(target_spec(), policy :: map()) :: {:ok, map()} | {:error, term()}
end
