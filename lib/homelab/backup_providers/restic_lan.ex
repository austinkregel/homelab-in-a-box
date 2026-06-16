defmodule Homelab.BackupProviders.ResticLan do
  @moduledoc """
  Tier-1 LAN restic backups (`:restic_lan`).

  Works without ZFS: `target_spec` may be `{:bind_mount_path, path}` when
  snapshots are unavailable, or `{:dataset, name}` with a `.zfs/snapshot/...`
  path when ZFS is available later.
  """

  @behaviour Homelab.Behaviours.BackupProviderV2

  alias Homelab.BackupProviders.Restic.Driver
  alias Homelab.Backups.TargetSpec
  alias Homelab.Storage.Secrets

  @impl true
  def driver_id, do: "restic_lan"

  @impl true
  def display_name, do: "Restic (LAN)"

  @impl true
  def description, do: "Encrypted incremental backups to on-LAN storage (CIFS/NFS path)"

  @impl true
  def tier, do: :restic_lan

  @impl true
  def capture(target_spec, opts) do
    with {:ok, {repo_url, password_ref, paths, tags}} <- resolve_target(target_spec, opts),
         :ok <- ensure_repo(repo_url, password_ref, opts),
         {:ok, result} <- Driver.impl().backup(repo_url, password_ref, paths, tags, env(opts)) do
      {:ok,
       %{
         provider: __MODULE__,
         tier: :restic_lan,
         id: result.snapshot_id,
         created_at: DateTime.utc_now(),
         metadata: %{
           repo_url: repo_url,
           paths: paths,
           bytes_added: result.bytes_added
         }
       }}
    end
  end

  @impl true
  def verify(handle) do
    repo = get_in(handle.metadata, ["repo_url"]) || get_in(handle.metadata, [:repo_url])

    if repo do
      Driver.impl().check(repo, password_ref_from_handle(handle), %{})
    else
      {:ok, %{"skipped" => true}}
    end
  end

  @impl true
  def restore(handle, into_spec, opts) do
    target_path =
      case into_spec do
        {:bind_mount_path, p} -> p
        {:dataset, _} -> Keyword.get(opts, :restore_mount, "/tmp/homelab-restore")
        other -> Keyword.get(opts, :restore_mount, inspect(other))
      end

    repo = get_in(handle.metadata, ["repo_url"]) || get_in(handle.metadata, [:repo_url])

    case Driver.impl().restore(
           repo,
           password_ref_from_handle(handle),
           handle.id,
           target_path,
           env(opts)
         ) do
      :ok -> {:ok, %{target_path: target_path}}
      err -> err
    end
  end

  @impl true
  def list(%{repo_url: repo, password_ref: ref}) do
    Driver.impl().list_snapshots(repo, ref, [], %{})
    |> case do
      {:ok, snaps} ->
        handles =
          Enum.map(snaps, fn s ->
            %{
              provider: __MODULE__,
              tier: :restic_lan,
              id: s.id,
              created_at: s.time || DateTime.utc_now(),
              metadata: %{repo_url: repo}
            }
          end)

        {:ok, handles}

      err ->
        err
    end
  end

  def list(_), do: {:ok, []}

  @impl true
  def prune(target_spec, policy) do
    with {:ok, {repo_url, password_ref, _, _}} <- resolve_target(target_spec, %{}) do
      Driver.impl().forget(repo_url, password_ref, policy, %{})
    end
  end

  # --- Helpers ---

  defp resolve_target(spec, opts) do
    tenant_slug = Keyword.get(opts, :tenant_slug, "default")

    with paths when is_list(paths) <- backup_paths(spec, opts) do
      repo_base = Keyword.get(opts, :repo_base, restic_lan_repo_base())
      repo_url = Path.join(repo_base, tenant_slug <> "/lan")
      password_ref = "secret/homelab/restic/#{tenant_slug}/lan"
      _ = password_for_tenant(tenant_slug)

      {:ok, {repo_url, {:vault, password_ref}, paths, Keyword.get(opts, :tags, [])}}
    end
  end

  defp backup_paths({:bind_mount_path, path}, _opts), do: [path]

  defp backup_paths({:dataset, dataset}, opts) do
    snapshot = Keyword.get(opts, :snapshot_name)

    if snapshot && Homelab.Storage.available?() do
      [Path.join(["/", dataset, ".zfs", "snapshot", snapshot])]
    else
      # Without ZFS, fall back to live mount if configured
      mount = Keyword.get(opts, :dataset_mount, "/#{dataset}")
      [mount]
    end
  end

  defp backup_paths(spec, opts) when is_map(spec) do
    case TargetSpec.decode(spec) do
      {:ok, decoded} -> backup_paths(decoded, opts)
      _ -> {:error, :invalid_target_spec}
    end
  end

  defp backup_paths(_, _), do: {:error, :invalid_target_spec}

  defp ensure_repo(repo_url, {:vault, ref}, opts) do
    password_ref = {:vault, ref}

    case Driver.impl().init_repo(repo_url, password_ref, env(opts)) do
      :ok ->
        :ok

      {:error, {:restic_failed, _code, output}} ->
        if String.contains?(output, "already exists"),
          do: :ok,
          else: {:error, {:init_failed, output}}

      err ->
        err
    end
  end

  defp env(opts) when is_list(opts), do: Keyword.get(opts, :env, %{})
  defp env(opts) when is_map(opts), do: Map.get(opts, :env, %{})
  defp env(_), do: %{}

  defp restic_lan_repo_base do
    Homelab.Settings.get("restic.lan.repo_base") || "/media/backups/restic"
  end

  defp password_ref_from_handle(handle) do
    ref = get_in(handle.metadata, ["password_ref"]) || get_in(handle.metadata, [:password_ref])
    {:vault, ref || "secret/homelab/restic/default/lan"}
  end

  @doc "Resolves or auto-generates the per-tenant LAN restic password (§20)."
  def password_for_tenant(tenant_slug) do
    Secrets.read_or_generate(
      "secret/homelab/restic/#{tenant_slug}/lan",
      &Secrets.random_password/0
    )
  end
end
