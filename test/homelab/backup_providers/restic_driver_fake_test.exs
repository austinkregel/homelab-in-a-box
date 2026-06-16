defmodule Homelab.BackupProviders.Restic.Driver.FakeTest do
  use ExUnit.Case, async: false

  alias Homelab.BackupProviders.Restic.Driver.Fake

  setup do
    start_supervised!(Fake)
    :ok
  end

  @repo "/tmp/fake-repo"
  @pw {:plaintext, "fake-pw"}

  test "init_repo records initialized timestamp" do
    assert :ok = Fake.init_repo(@repo, @pw, %{})
    assert %{repos: %{@repo => %{initialized_at: %DateTime{}}}} = Fake.__state__()
  end

  test "backup returns a synthesized snapshot result and persists snapshot" do
    Fake.init_repo(@repo, @pw, %{})

    assert {:ok, %{snapshot_id: snap_id, total_bytes: 1024}} =
             Fake.backup(@repo, @pw, ["/data/foo"], ["app:foo"], %{})

    assert is_binary(snap_id)
    assert String.length(snap_id) >= 8

    {:ok, [snap]} = Fake.list_snapshots(@repo, @pw, [], %{})
    assert snap.id == snap_id
    assert snap.paths == ["/data/foo"]
    assert "app:foo" in snap.tags
  end

  test "list_snapshots filters by tag" do
    Fake.init_repo(@repo, @pw, %{})
    {:ok, _} = Fake.backup(@repo, @pw, ["/data/foo"], ["app:foo"], %{})
    {:ok, _} = Fake.backup(@repo, @pw, ["/data/bar"], ["app:bar"], %{})

    {:ok, foo_snaps} = Fake.list_snapshots(@repo, @pw, [tags: ["app:foo"]], %{})
    assert length(foo_snaps) == 1
    assert hd(foo_snaps).paths == ["/data/foo"]
  end

  test "forget records the policy that was applied" do
    Fake.init_repo(@repo, @pw, %{})
    policy = %{keep_daily: 7, keep_weekly: 4}
    assert {:ok, %{"kept" => _}} = Fake.forget(@repo, @pw, policy, %{})
    assert [{@repo, ^policy}] = Fake.__state__().forgets
  end

  test "restore creates the target directory" do
    target = Path.join(System.tmp_dir!(), "restic-fake-#{System.unique_integer([:positive])}")
    assert :ok = Fake.restore(@repo, @pw, "deadbeef", target, %{})
    assert File.dir?(target)
    File.rm_rf!(target)
  end

  test "check always succeeds" do
    assert :ok = Fake.check(@repo, @pw, %{})
  end
end
