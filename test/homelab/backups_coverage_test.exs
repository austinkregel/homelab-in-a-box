defmodule Homelab.BackupsCoverageTest do
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Backups
  alias Homelab.BackupTarget

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
    setup do
      paths = BackupTarget.configure_local()
      template = insert(:app_template, slug: "plex")
      deployment = insert(:deployment, app_template: template)
      BackupTarget.seed_service!("plex", %{"a.txt" => "data"})

      Map.merge(paths, %{deployment: deployment})
    end

    # An archive outlives the deployment that wrote it: destroying a deployment deletes
    # its rows by cascade and never touches storage. Orphans are what that leaves
    # behind — real bytes, costing real space, that nothing else can see.
    test "marks an archive no backup job points at as orphaned", %{
      deployment: deployment,
      backup_root: root
    } do
      job = insert(:backup_job, deployment: deployment)
      {:ok, tracked} = Backups.execute_backup(job)

      File.mkdir_p!(Path.join([root, "plex/19990101T000000Z", "frames"]))
      File.write!(Path.join([root, "plex/19990101T000000Z", "frames", "00000000"]), "x")

      assert {:ok, objects} = Backups.repo_snapshots()

      assert %{state: :tracked} = Enum.find(objects, &(&1.id == tracked.archive_key))
      assert %{state: :orphaned} = Enum.find(objects, &(&1.id == "plex/19990101T000000Z"))
    end

    test "reports an unconfigured destination rather than pretending it is empty" do
      BackupTarget.unconfigure()

      assert {:error, :no_target_configured} = Backups.repo_snapshots()
    end

    # Reading the destination touches storage that may be unmounted or unreachable.
    # This backs a page that already renders an error state; it must not take it down.
    test "reports a destination that raises rather than taking the page down" do
      Homelab.Settings.set("backup_root", "relative/not/absolute", category: "backups")
      on_exit(fn -> Homelab.Settings.evict("backup_root") end)

      assert {:error, _} = Backups.repo_snapshots()
    end
  end
end
