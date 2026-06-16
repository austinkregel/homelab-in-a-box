defmodule Homelab.BackupProviders.Restic.Driver.Cli do
  @moduledoc """
  Production `Homelab.BackupProviders.Restic.Driver` implementation.

  Shells out to the `restic` binary, always passing `--json` for parseable
  output. Passwords are materialized just-in-time from Vault refs into the
  process environment (`RESTIC_PASSWORD`) so they never appear in argv or
  on disk.

  This driver runs *inside* the BEAM container — restic itself only needs
  filesystem and network access, not host privileges. Source paths that
  come from `.zfs/snapshot/...` are passed through from the caller; the
  caller is responsible for getting that snapshot mount path right.
  """

  @behaviour Homelab.BackupProviders.Restic.Driver

  require Logger

  alias Homelab.Storage.Secrets

  @impl true
  def init_repo(repo_url, password_ref, env) do
    run(["init"], repo_url, password_ref, env, [])
    |> ok_or_error()
  end

  @impl true
  def backup(repo_url, password_ref, paths, tags, env) do
    tag_args = Enum.flat_map(tags, fn t -> ["--tag", t] end)

    case run(["backup" | paths] ++ tag_args ++ ["--json"], repo_url, password_ref, env, []) do
      {:ok, output} -> parse_backup_output(output)
      {:error, _} = err -> err
    end
  end

  @impl true
  def list_snapshots(repo_url, password_ref, filter, env) do
    args =
      ["snapshots", "--json"] ++
        Enum.flat_map(filter, fn
          {:tags, tags} -> Enum.flat_map(tags, fn t -> ["--tag", t] end)
          {:host, h} -> ["--host", h]
          {:path, p} -> ["--path", p]
          _ -> []
        end)

    case run(args, repo_url, password_ref, env, []) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, snaps} when is_list(snaps) -> {:ok, Enum.map(snaps, &normalize_snapshot/1)}
          _ -> {:ok, []}
        end

      err ->
        err
    end
  end

  @impl true
  def restore(repo_url, password_ref, snapshot_id, target_path, env) do
    run(
      ["restore", snapshot_id, "--target", target_path],
      repo_url,
      password_ref,
      env,
      []
    )
    |> ok_or_error()
  end

  @impl true
  def forget(repo_url, password_ref, policy, env) do
    args = ["forget", "--prune", "--json"] ++ build_keep_args(policy)

    case run(args, repo_url, password_ref, env, []) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, parsed} -> {:ok, parsed}
          {:error, _} -> {:ok, %{"output" => output}}
        end

      err ->
        err
    end
  end

  @impl true
  def check(repo_url, password_ref, env) do
    run(["check"], repo_url, password_ref, env, []) |> ok_or_error()
  end

  # --- Internals ---

  defp run(args, repo_url, password_ref, env, opts) do
    binary = System.find_executable("restic") || "restic"
    password = resolve_password!(password_ref)

    full_env =
      env
      |> Map.put("RESTIC_REPOSITORY", repo_url)
      |> Map.put("RESTIC_PASSWORD", password)
      |> Map.to_list()
      |> Enum.map(fn {k, v} -> {to_string(k), to_string(v)} end)

    Logger.debug(fn -> "[restic] #{Enum.join(args, " ")}" end)

    cmd_opts = [stderr_to_stdout: true, env: full_env] ++ Keyword.take(opts, [:cd])

    case System.cmd(binary, args, cmd_opts) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_code} ->
        Logger.error("[restic] exit #{exit_code}: #{output}")
        {:error, {:restic_failed, exit_code, output}}
    end
  end

  defp resolve_password!({:vault, ref}), do: Secrets.read!(ref)
  defp resolve_password!({:plaintext, pw}), do: pw

  defp parse_backup_output(output) do
    summary =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(line) do
          {:ok, %{"message_type" => "summary"} = m} -> m
          _ -> nil
        end
      end)

    case summary do
      nil ->
        {:error, {:no_summary, output}}

      m ->
        {:ok,
         %{
           snapshot_id: m["snapshot_id"] || "",
           files_new: m["files_new"] || 0,
           files_changed: m["files_changed"] || 0,
           files_unmodified: m["files_unmodified"] || 0,
           bytes_added: m["data_added"] || 0,
           total_bytes: m["total_bytes_processed"] || 0
         }}
    end
  end

  defp normalize_snapshot(s) do
    time =
      case DateTime.from_iso8601(s["time"] || "") do
        {:ok, dt, _} -> dt
        _ -> nil
      end

    %{
      id: s["id"] || "",
      short_id: s["short_id"] || "",
      time: time,
      hostname: s["hostname"],
      tags: s["tags"] || [],
      paths: s["paths"] || [],
      tree: s["tree"]
    }
  end

  defp build_keep_args(policy) do
    policy
    |> Map.to_list()
    |> Enum.flat_map(fn
      {:keep_last, n} -> ["--keep-last", to_string(n)]
      {:keep_hourly, n} -> ["--keep-hourly", to_string(n)]
      {:keep_daily, n} -> ["--keep-daily", to_string(n)]
      {:keep_weekly, n} -> ["--keep-weekly", to_string(n)]
      {:keep_monthly, n} -> ["--keep-monthly", to_string(n)]
      {:keep_yearly, n} -> ["--keep-yearly", to_string(n)]
      {:keep_tag, tags} when is_list(tags) -> Enum.flat_map(tags, &["--keep-tag", &1])
      _ -> []
    end)
  end

  defp ok_or_error({:ok, _}), do: :ok
  defp ok_or_error({:error, _} = err), do: err
end
