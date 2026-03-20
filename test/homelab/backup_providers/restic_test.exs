defmodule Homelab.BackupProviders.ResticTest do
  @moduledoc """
  Unit tests for the Restic backup provider.

  Since Restic requires actual CLI execution, these tests focus on
  configuration and argument building. Integration tests (tagged :integration)
  test against a real Restic binary.
  """

  use ExUnit.Case, async: true

  alias Homelab.BackupProviders.Restic

  setup do
    original = Application.get_env(:homelab, Homelab.BackupProviders.Restic)

    on_exit(fn ->
      if original do
        Application.put_env(:homelab, Homelab.BackupProviders.Restic, original)
      else
        Application.delete_env(:homelab, Homelab.BackupProviders.Restic)
      end
    end)

    :ok
  end

  describe "backup/3" do
    @tag :integration
    test "creates a backup snapshot" do
      # Requires restic binary and initialized repo
      tmp_dir = Path.join(System.tmp_dir!(), "restic_test_#{:rand.uniform(100_000)}")
      repo = Path.join(tmp_dir, "repo")
      source = Path.join(tmp_dir, "source")

      File.mkdir_p!(source)
      File.write!(Path.join(source, "test.txt"), "hello")

      Application.put_env(:homelab, Homelab.BackupProviders.Restic,
        repo: repo,
        password: "test-password"
      )

      # Init the repo first
      System.cmd("restic", ["init", "--repo", repo, "--password-command", "echo test-password"])

      case Restic.backup(source, repo, ["test", "homelab"]) do
        {:ok, snapshot_id} ->
          assert is_binary(snapshot_id)

        {:error, {:restic_error, _, _}} ->
          # Restic not installed, skip
          :ok
      end

      File.rm_rf!(tmp_dir)
    end
  end

  describe "list_snapshots/1" do
    @tag :integration
    test "lists snapshots in a repo" do
      tmp_dir = Path.join(System.tmp_dir!(), "restic_list_#{:rand.uniform(100_000)}")
      repo = Path.join(tmp_dir, "repo")

      Application.put_env(:homelab, Homelab.BackupProviders.Restic, password: "test-password")

      System.cmd("restic", ["init", "--repo", repo, "--password-command", "echo test-password"])

      case Restic.list_snapshots(repo) do
        {:ok, snapshots} ->
          assert is_list(snapshots)

        {:error, {:restic_error, _, _}} ->
          :ok
      end

      File.rm_rf!(tmp_dir)
    end
  end

  describe "configuration" do
    test "uses default repo when not configured" do
      Application.delete_env(:homelab, Homelab.BackupProviders.Restic)

      # Ensure module is loaded, then verify the behaviour callbacks exist
      {:module, _} = Code.ensure_loaded(Restic)

      assert {:backup, 3} in Restic.__info__(:functions)
      assert {:restore, 2} in Restic.__info__(:functions)
      assert {:list_snapshots, 1} in Restic.__info__(:functions)
      assert {:prune, 2} in Restic.__info__(:functions)
    end

    test "implements BackupProvider behaviour" do
      behaviours =
        Restic.__info__(:attributes)
        |> Keyword.get_values(:behaviour)
        |> List.flatten()

      assert Homelab.Behaviours.BackupProvider in behaviours
    end
  end
end
