defmodule Homelab.Workbench do
  @moduledoc """
  A disk-backed scratch workspace for the Workbench build editor.

  Each user gets a private directory under the configured `root`, keyed by their
  id. Files uploaded in the UI land here and are joined into the Docker build
  context alongside the text files authored in the editor. There is **no
  database** behind this — the workspace is throwaway state, purged after a TTL
  by `Homelab.Services.WorkbenchJanitor`.

  Safety rules:

    * File names are validated to be plain relative paths — no absolute paths and
      no `..` traversal segments — so a workspace can never write outside its own
      directory.
    * A per-user quota (`quota_bytes`, default 1 GB) caps total workspace size;
      an add that would exceed it returns `{:error, :quota_exceeded}` and writes
      nothing.

  Configured via:

      config :homelab, :workbench,
        root: <tmp dir>,
        quota_bytes: 1_073_741_824,
        ttl_hours: 24
  """

  @doc "The absolute path to a user's workspace directory (not created)."
  def workspace_dir(user_id) do
    Path.join(root(), "user-#{user_id}")
  end

  @doc """
  Lists the files in a user's workspace as `%{name:, size:, path:}` maps,
  sorted by name. Missing workspace → `[]`.
  """
  def list_files(user_id) do
    dir = workspace_dir(user_id)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.map(fn name ->
          path = Path.join(dir, name)

          size =
            case File.stat(path) do
              {:ok, %File.Stat{size: size}} -> size
              _ -> 0
            end

          %{name: name, size: size, path: path}
        end)
        |> Enum.reject(&is_nil(&1.name))
        |> Enum.sort_by(& &1.name)

      {:error, _} ->
        []
    end
  end

  @doc """
  Copies the file at `source_path` into the user's workspace under `name`.

  Rejects unsafe names (`{:error, :invalid_name}`) and enforces the per-user
  quota (`{:error, :quota_exceeded}`). On success returns `{:ok, %{name:, size:}}`.
  """
  def add_file(user_id, name, source_path) do
    dir = workspace_dir(user_id)

    with {:ok, dest} <- safe_path(dir, name),
         {:ok, %File.Stat{size: incoming}} <- File.stat(source_path),
         :ok <- check_quota(user_id, name, incoming) do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(source_path, dest)
      {:ok, %{name: name, size: incoming}}
    end
  end

  @doc "Removes a file from the user's workspace. Missing file is still `:ok`."
  def delete_file(user_id, name) do
    dir = workspace_dir(user_id)

    case safe_path(dir, name) do
      {:ok, path} ->
        _ = File.rm(path)
        :ok

      error ->
        error
    end
  end

  @doc "Total bytes currently used by a user's workspace."
  def total_size(user_id) do
    user_id
    |> list_files()
    |> Enum.reduce(0, fn %{size: size}, acc -> acc + size end)
  end

  @doc "The configured per-user quota in bytes."
  def quota_bytes do
    config(:quota_bytes, 1_073_741_824)
  end

  @doc """
  Deletes workspace directories whose most-recent modification is older than the
  configured TTL. Returns the number of workspaces purged.
  """
  def purge_stale do
    cutoff = System.system_time(:second) - ttl_hours() * 3600

    case File.ls(root()) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root(), &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.reduce(0, fn dir, acc ->
          if stale?(dir, cutoff) do
            _ = File.rm_rf(dir)
            acc + 1
          else
            acc
          end
        end)

      {:error, _} ->
        0
    end
  end

  # --- internals ---

  # A workspace is stale when its directory's own mtime (bumped whenever a file
  # is added/removed) is older than the cutoff.
  defp stale?(dir, cutoff) do
    case File.stat(dir, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime <= cutoff
      _ -> false
    end
  end

  defp check_quota(user_id, name, incoming) do
    # A same-named file is being replaced, so its current bytes free up.
    existing =
      user_id
      |> list_files()
      |> Enum.find_value(0, fn f -> if f.name == name, do: f.size end)

    if total_size(user_id) - existing + incoming > quota_bytes() do
      {:error, :quota_exceeded}
    else
      :ok
    end
  end

  defp safe_path(dir, name) do
    cond do
      is_nil(name) or name == "" -> {:error, :invalid_name}
      Path.type(name) != :relative -> {:error, :invalid_name}
      ".." in Path.split(name) -> {:error, :invalid_name}
      true -> {:ok, Path.join(dir, name)}
    end
  end

  defp root, do: config(:root, Path.join(System.tmp_dir!(), "homelab-workbench"))
  defp ttl_hours, do: config(:ttl_hours, 24)

  defp config(key, default) do
    :homelab
    |> Application.get_env(:workbench, [])
    |> Keyword.get(key, default)
  end
end
