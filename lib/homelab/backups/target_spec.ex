defmodule Homelab.Backups.TargetSpec do
  @moduledoc """
  Encodes and decodes `target_ref` JSON stored on `backup_jobs` and
  `backup_schedules` into the tagged tuples used by `BackupProviderV2`.
  """

  @type t :: Homelab.Behaviours.BackupProviderV2.target_spec()

  def encode({:dataset, name}), do: %{"type" => "dataset", "name" => name}

  def encode({:restic_repo, url, {:vault_ref, ref}}),
    do: %{"type" => "restic_repo", "url" => url, "password_ref" => ref}

  def encode({:replication_target, node_id, dataset}),
    do: %{"type" => "replication_target", "node_id" => node_id, "dataset" => dataset}

  def encode({:bind_mount_path, path}),
    do: %{"type" => "bind_mount_path", "path" => path}

  def decode(%{"type" => "dataset", "name" => name}), do: {:ok, {:dataset, name}}

  def decode(%{"type" => "restic_repo", "url" => url, "password_ref" => ref}),
    do: {:ok, {:restic_repo, url, {:vault_ref, ref}}}

  def decode(%{"type" => "replication_target", "node_id" => nid, "dataset" => ds}),
    do: {:ok, {:replication_target, nid, ds}}

  def decode(%{"type" => "bind_mount_path", "path" => path}),
    do: {:ok, {:bind_mount_path, path}}

  def decode(_), do: {:error, :invalid_target_ref}

  def decode!(map) do
    case decode(map) do
      {:ok, spec} -> spec
      {:error, _} -> raise ArgumentError, "invalid target_ref: #{inspect(map)}"
    end
  end
end
