defmodule Homelab.BackupProviders.Restic.Driver.Fake do
  @moduledoc """
  In-memory fake `Homelab.BackupProviders.Restic.Driver` implementation.

  Tracks initialized repos, snapshots per repo, and forget operations.
  Useful for tests of `ResticLan`/`ResticOffsite` orchestration where we
  want to assert end-to-end "snapshot → backup → list → prune → restore"
  flows without spawning the real `restic` binary.

  For one-shot expectations use `Homelab.Mocks.Restic.Driver` (Mox).
  """

  @behaviour Homelab.BackupProviders.Restic.Driver

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    initial = %{repos: %{}, snapshots: %{}, forgets: []}
    Agent.start_link(fn -> initial end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  def __state__(name \\ __MODULE__), do: Agent.get(name, & &1)

  @impl true
  def init_repo(repo_url, _password_ref, _env) do
    Agent.update(__MODULE__, fn s ->
      %{s | repos: Map.put(s.repos, repo_url, %{initialized_at: DateTime.utc_now()})}
    end)

    :ok
  end

  @impl true
  def backup(repo_url, _password_ref, paths, tags, _env) do
    Agent.get_and_update(__MODULE__, fn s ->
      snap_id = random_id()
      now = DateTime.utc_now()

      snapshot = %{
        id: snap_id,
        short_id: String.slice(snap_id, 0, 8),
        time: now,
        hostname: "fake-host",
        tags: tags,
        paths: paths,
        tree: random_id()
      }

      new_snapshots = Map.update(s.snapshots, repo_url, [snapshot], &[snapshot | &1])

      result = %{
        snapshot_id: snap_id,
        files_new: 1,
        files_changed: 0,
        files_unmodified: 0,
        bytes_added: 1024,
        total_bytes: 1024
      }

      {{:ok, result}, %{s | snapshots: new_snapshots}}
    end)
  end

  @impl true
  def list_snapshots(repo_url, _password_ref, filter, _env) do
    snaps =
      Agent.get(__MODULE__, fn s -> Map.get(s.snapshots, repo_url, []) end)

    filtered =
      case Keyword.get(filter, :tags) do
        nil ->
          snaps

        tags ->
          Enum.filter(snaps, fn snap ->
            Enum.any?(tags, &(&1 in snap.tags))
          end)
      end

    {:ok, filtered}
  end

  @impl true
  def restore(_repo_url, _password_ref, _snapshot_id, target_path, _env) do
    File.mkdir_p(target_path)
    :ok
  end

  @impl true
  def forget(repo_url, _password_ref, policy, _env) do
    Agent.update(__MODULE__, fn s ->
      %{s | forgets: [{repo_url, policy} | s.forgets]}
    end)

    {:ok, %{"forgot" => 0, "kept" => 0}}
  end

  @impl true
  def check(_repo_url, _password_ref, _env), do: :ok

  defp random_id do
    :crypto.strong_rand_bytes(32) |> Base.encode16(case: :lower)
  end
end
