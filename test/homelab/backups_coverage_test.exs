defmodule Homelab.BackupsCoverageTest do
  use Homelab.DataCase, async: false

  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  alias Homelab.Backups

  describe "coverage/0" do
    test "reports an app with no backup job as unprotected" do
      insert(:deployment)

      assert [%{state: :unprotected, last_completed_at: nil}] = Backups.coverage()
    end

    test "reports an app whose jobs never completed as unverified" do
      deployment = insert(:deployment)
      insert(:backup_job, deployment: deployment, status: :failed)

      assert [%{state: :unverified}] = Backups.coverage()
    end

    test "reports an app with a completed job as protected, with its time" do
      deployment = insert(:deployment)
      at = ~U[2026-03-02 10:00:00Z]
      insert(:backup_job, deployment: deployment, status: :completed, completed_at: at)

      assert [%{state: :protected, last_completed_at: ^at}] = Backups.coverage()
    end

    test "keeps a row for every app, so the page cannot go empty" do
      insert(:deployment)
      insert(:deployment)

      assert length(Backups.coverage()) == 2
    end
  end

  describe "repo_snapshots/0" do
    test "marks a snapshot no backup job points at as orphaned" do
      deployment = insert(:deployment)
      insert(:backup_job, deployment: deployment, status: :completed, snapshot_id: "keep01")

      Homelab.Mocks.BackupProvider
      |> stub(:repo, fn -> "/backups/repo" end)
      |> expect(:list_snapshots, fn "/backups/repo" ->
        {:ok,
         [
           %{
             id: "keep01",
             time: "2026-03-02T10:00:00Z",
             hostname: "box",
             tags: [],
             paths: ["/data"]
           },
           %{
             id: "gone42",
             time: "2026-02-01T10:00:00Z",
             hostname: "box",
             tags: [],
             paths: ["/data"]
           }
         ]}
      end)

      assert {:ok, snapshots} = Backups.repo_snapshots()
      assert %{id: "keep01", state: :tracked} = Enum.find(snapshots, &(&1.id == "keep01"))
      assert %{id: "gone42", state: :orphaned} = Enum.find(snapshots, &(&1.id == "gone42"))
    end

    test "reports a provider that raises rather than taking the page down" do
      Homelab.Mocks.BackupProvider
      |> stub(:repo, fn -> "/backups/repo" end)
      |> expect(:list_snapshots, fn _repo -> raise "restic: repository is locked" end)

      assert {:error, message} = Backups.repo_snapshots()
      assert message =~ "repository is locked"
    end

    test "reports a repository it cannot read rather than pretending it is empty" do
      Homelab.Mocks.BackupProvider
      |> stub(:repo, fn -> "/backups/repo" end)
      |> expect(:list_snapshots, fn _repo -> {:error, :repo_unreachable} end)

      assert {:error, :repo_unreachable} = Backups.repo_snapshots()
    end
  end
end
