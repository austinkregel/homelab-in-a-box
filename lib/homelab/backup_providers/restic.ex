defmodule Homelab.BackupProviders.Restic do
  @moduledoc """
  Restic-based backup provider implementation.

  Uses the Restic CLI to manage encrypted, deduplicated backups.
  Supports local, S3, SFTP, and other Restic-supported backends.

  Configuration:
    config :homelab, Homelab.BackupProviders.Restic,
      repo: "/backups/restic-repo",
      password_file: "/etc/homelab/restic-password",
      extra_args: []
  """

  @behaviour Homelab.Behaviours.BackupProvider

  require Logger

  @impl true
  def driver_id, do: "restic"

  @impl true
  def display_name, do: "Restic"

  @impl true
  def description,
    do: "Encrypted, deduplicated backups with support for local, S3, and SFTP backends"

  @impl true
  def backup(source_path, repo, tags) do
    tag_args = Enum.flat_map(tags, fn tag -> ["--tag", tag] end)

    args =
      ["backup", source_path, "--repo", repo, "--json"] ++
        tag_args ++
        password_args() ++
        extra_args()

    case run_restic(args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, %{"snapshot_id" => id}} ->
            {:ok, id}

          {:ok, parsed} when is_map(parsed) ->
            # Try to extract snapshot ID from any response format
            id = parsed["id"] || "unknown"
            {:ok, id}

          {:error, _} ->
            # If JSON parsing fails, try to extract snapshot ID from text
            extract_snapshot_id(output)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def restore(snapshot_id, target_path) do
    args =
      ["restore", snapshot_id, "--target", target_path, "--repo", default_repo()] ++
        password_args() ++
        extra_args()

    case run_restic(args) do
      {:ok, _output} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def list_snapshots(repo) do
    args =
      ["snapshots", "--repo", repo, "--json"] ++
        password_args() ++
        extra_args()

    case run_restic(args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, snapshots} when is_list(snapshots) ->
            {:ok,
             Enum.map(snapshots, fn s ->
               %{
                 id: s["short_id"] || s["id"],
                 time: s["time"],
                 hostname: s["hostname"],
                 tags: s["tags"] || [],
                 paths: s["paths"] || []
               }
             end)}

          {:ok, _} ->
            {:ok, []}

          {:error, _} ->
            {:ok, []}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def prune(repo, policy) do
    keep_args = build_keep_args(policy)

    args =
      ["forget", "--prune", "--repo", repo, "--json"] ++
        keep_args ++
        password_args() ++
        extra_args()

    case run_restic(args) do
      {:ok, output} ->
        case Jason.decode(output) do
          {:ok, result} -> {:ok, result}
          {:error, _} -> {:ok, %{"output" => output}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Helpers ---

  defp run_restic(args) do
    restic_path = System.find_executable("restic") || "restic"

    Logger.debug("Running restic: #{restic_path} #{Enum.join(args, " ")}")

    case System.cmd(restic_path, args, stderr_to_stdout: true) do
      {output, 0} ->
        {:ok, String.trim(output)}

      {output, exit_code} ->
        Logger.error("Restic failed (exit #{exit_code}): #{output}")
        {:error, {:restic_error, exit_code, output}}
    end
  end

  defp password_args do
    config = config()

    cond do
      password_file = Keyword.get(config, :password_file) ->
        ["--password-file", password_file]

      password = Keyword.get(config, :password) ->
        ["--password-command", "echo #{password}"]

      true ->
        []
    end
  end

  defp extra_args do
    config = config()
    Keyword.get(config, :extra_args, [])
  end

  defp default_repo do
    config = config()
    Keyword.get(config, :repo, "/backups/restic-repo")
  end

  defp config do
    Application.get_env(:homelab, __MODULE__, [])
  end

  defp build_keep_args(policy) do
    []
    |> maybe_add("--keep-last", policy["keep_last"] || policy[:keep_last])
    |> maybe_add("--keep-daily", policy["keep_daily"] || policy[:keep_daily])
    |> maybe_add("--keep-weekly", policy["keep_weekly"] || policy[:keep_weekly])
    |> maybe_add("--keep-monthly", policy["keep_monthly"] || policy[:keep_monthly])
  end

  defp maybe_add(args, _flag, nil), do: args
  defp maybe_add(args, flag, value), do: args ++ [flag, to_string(value)]

  defp extract_snapshot_id(output) do
    case Regex.run(~r/snapshot ([a-f0-9]+) saved/, output) do
      [_, id] -> {:ok, id}
      _ -> {:error, {:parse_error, output}}
    end
  end
end
