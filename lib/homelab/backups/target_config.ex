defmodule Homelab.Backups.TargetConfig do
  @moduledoc """
  Resolves the operator's chosen backup destination from Settings.

  Settings rather than a table because that is how every other driver here is
  configured — DNS tokens, registrar keys, the OIDC secret — and because one instance
  writes to one destination. Several destinations at once needs a `backup_targets`
  table, and this is deliberately the smaller thing.

  Nothing is guessed. An unconfigured or half-configured destination returns an error
  naming what is missing, so a backup refuses rather than writing somewhere nobody
  chose and nobody can find again.
  """

  alias Homelab.Backups.Targets.{LocalDisk, S3}
  alias Homelab.Settings

  @kind_setting "backup_target_kind"
  @compression_setting "backup_compression"

  @doc "The configured target, or why there isn't one."
  @spec resolve() :: {:ok, module(), map()} | {:error, term()}
  def resolve do
    case Settings.get(@kind_setting) do
      "local_disk" -> local_disk()
      "s3" -> s3()
      nil -> {:error, :no_target_configured}
      other -> {:error, {:unknown_target_kind, other}}
    end
  end

  @doc "True once a destination is configured well enough to attempt a backup."
  @spec configured?() :: boolean()
  def configured?, do: match?({:ok, _, _}, resolve())

  @doc "`:gzip` unless the operator turned it off for this instance."
  @spec compression() :: :gzip | :none
  def compression do
    case Settings.get(@compression_setting) do
      "none" -> :none
      _ -> :gzip
    end
  end

  @doc "The setting keys this module reads, so the UI and tests agree on their names."
  def settings_keys do
    %{
      kind: @kind_setting,
      compression: @compression_setting,
      root: "backup_root",
      s3: %{
        endpoint: "backup_s3_endpoint",
        bucket: "backup_s3_bucket",
        region: "backup_s3_region",
        prefix: "backup_s3_prefix",
        access_key_id: "backup_s3_access_key_id",
        secret_access_key: "backup_s3_secret_access_key",
        storage_class: "backup_s3_storage_class"
      }
    }
  end

  @doc "Which target module a stored kind refers to."
  def module_for("local_disk"), do: {:ok, LocalDisk}
  def module_for("s3"), do: {:ok, S3}
  def module_for(other), do: {:error, {:unknown_target_kind, other}}

  # -- kinds --

  defp local_disk do
    case present(Settings.get("backup_root")) do
      nil ->
        {:error, {:missing_settings, ["backup_root"]}}

      root ->
        if Path.type(root) == :absolute do
          {:ok, LocalDisk, %{root: root}}
        else
          {:error, {:relative_backup_root, root}}
        end
    end
  end

  defp s3 do
    keys = settings_keys().s3

    required = [:endpoint, :bucket, :access_key_id, :secret_access_key]
    values = Map.new(required, fn key -> {key, present(Settings.get(keys[key]))} end)

    case Enum.filter(required, &is_nil(values[&1])) do
      [] ->
        {:ok, S3,
         values
         |> Map.put(:region, Settings.get(keys.region) || "us-east-1")
         |> Map.put(:prefix, Settings.get(keys.prefix) || "")
         |> Map.put(:storage_class, present(Settings.get(keys.storage_class)))}

      missing ->
        {:error, {:missing_settings, Enum.map(missing, &keys[&1])}}
    end
  end

  defp present(nil), do: nil
  defp present(""), do: nil
  defp present(value) when is_binary(value), do: String.trim(value)
end
