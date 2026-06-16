defmodule Homelab.BackupProviders.ResticOffsite do
  @moduledoc """
  Tier-3 monthly glacial restic backups to S3-compatible storage (`:restic_offsite`).
  """

  @behaviour Homelab.Behaviours.BackupProviderV2

  alias Homelab.Storage.Secrets

  @impl true
  def driver_id, do: "restic_offsite"

  @impl true
  def display_name, do: "Restic (Offsite)"

  @impl true
  def description, do: "Monthly encrypted backups to S3-compatible glacial storage"

  @impl true
  def tier, do: :restic_offsite

  @impl true
  def capture(target_spec, opts) do
    Homelab.BackupProviders.ResticLan.capture(target_spec, offsite_opts(opts))
    |> case do
      {:ok, handle} -> {:ok, %{handle | tier: :restic_offsite, provider: __MODULE__}}
      err -> err
    end
  end

  @impl true
  def verify(handle), do: Homelab.BackupProviders.ResticLan.verify(handle)

  @impl true
  def restore(handle, into, opts),
    do: Homelab.BackupProviders.ResticLan.restore(handle, into, opts)

  @impl true
  def list(filter), do: Homelab.BackupProviders.ResticLan.list(filter)

  @impl true
  def prune(target_spec, policy) do
    Homelab.BackupProviders.ResticLan.prune(target_spec, policy)
  end

  defp offsite_opts(opts) do
    tenant = Keyword.get(opts, :tenant_slug, "default")
    repo = Homelab.Settings.get("restic.offsite.repo") || "s3:s3.amazonaws.com/homelab-backups"

    opts
    |> Keyword.put(:repo_base, repo)
    |> Keyword.put(:tenant_slug, tenant)
    |> Keyword.update(:env, %{}, fn env ->
      s3_env(tenant) |> Map.merge(env)
    end)
  end

  defp s3_env(tenant) do
    case Secrets.read("secret/homelab/restic/#{tenant}/offsite/s3_creds") do
      {:ok, json} ->
        case Jason.decode(json) do
          {:ok, %{"access_key" => ak, "secret_key" => sk} = creds} ->
            %{
              "AWS_ACCESS_KEY_ID" => ak,
              "AWS_SECRET_ACCESS_KEY" => sk,
              "AWS_DEFAULT_REGION" => creds["region"] || "us-east-1"
            }

          _ ->
            %{}
        end

      _ ->
        %{}
    end
  end
end
