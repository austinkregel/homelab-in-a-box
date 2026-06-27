defmodule Homelab.Deployments.Backups.Strategy do
  @moduledoc """
  Behaviour for a backup mechanism used by the `:backup_verify` gate.

  The host has no CoW/snapshot tier (ext4, no reflink, no ZFS/btrfs/LVM — see the
  prod probe), so backups are copy-based. A strategy must do two things, and the
  gate only opens if BOTH succeed:

    * `backup/3` — produce a durable copy of `source` under `dest`, returning an
      artifact map describing it (at minimum `%{"path" => dest, ...}`).
    * `verify/2` — PROVE the artifact is restorable. A structural "the files
      exist" check is not enough; an implementation re-reads the stored copy and
      checks it against a recorded manifest (file copy), or reloads a logical
      dump into a throwaway instance and runs a sentinel check (DB dump).

  This split is what lets the saga refuse to stop/cut over a `:preserve` resource
  until a *verified* backup exists.
  """

  @callback backup(source :: String.t(), dest :: String.t(), opts :: keyword()) ::
              {:ok, map()} | {:error, term()}

  @callback verify(artifact :: map(), opts :: keyword()) :: :ok | {:error, term()}
end
