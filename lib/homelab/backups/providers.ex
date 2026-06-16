defmodule Homelab.Backups.Providers do
  @moduledoc """
  Resolves `BackupProviderV2` modules by tier. ZFS-backed tiers return
  `{:error, :storage_unavailable}` when the host agent is not present.
  """

  @zfs_tiers [:local_snapshot, :zfs_replicate]

  @tier_modules %{
    restic_lan: Homelab.BackupProviders.ResticLan,
    restic_offsite: Homelab.BackupProviders.ResticOffsite
  }

  @spec get(Homelab.Behaviours.BackupProviderV2.tier()) ::
          {:ok, module()} | {:error, :storage_unavailable | :not_implemented | :unknown_tier}
  def get(tier) when tier in @zfs_tiers do
    if Homelab.Storage.available?() do
      {:error, :not_implemented}
    else
      {:error, :storage_unavailable}
    end
  end

  def get(tier) do
    case Map.get(@tier_modules, tier) do
      nil -> {:error, :unknown_tier}
      mod -> {:ok, mod}
    end
  end

  @spec all_tiers() :: [Homelab.Behaviours.BackupProviderV2.tier()]
  def all_tiers, do: @zfs_tiers ++ Map.keys(@tier_modules)
end
