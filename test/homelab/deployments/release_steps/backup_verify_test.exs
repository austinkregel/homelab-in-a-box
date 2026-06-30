defmodule Homelab.Deployments.ReleaseSteps.BackupVerifyTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.ReleaseSteps.BackupVerify

  setup do
    base = Path.join(System.tmp_dir!(), "backupverify-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    backup_root = Path.join(base, "backups")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "data.txt"), "important")

    Application.put_env(:homelab, :backup_root, backup_root)

    on_exit(fn ->
      Application.delete_env(:homelab, :backup_root)
      File.rm_rf(base)
    end)

    %{src: src, backup_root: backup_root}
  end

  defp step(targets), do: %{id: 1, resource_handle: %{"targets" => targets}}
  defp ctx, do: %{deployment: %{id: "dep1"}, release: %{id: "rel1"}}

  test "backs up and verifies a preserve target, recording the handle", %{src: src} do
    s = step([%{"name" => "homelab-postgres", "path" => src, "tier" => "preserve"}])

    assert {:ok, handle} = BackupVerify.run(s, ctx())
    assert handle["verified"] == true
    assert [%{"target" => "homelab-postgres", "strategy" => "file_copy"}] = handle["backups"]
    assert File.exists?(Path.join([handle["root"], "0-homelab-postgres", "data", "data.txt"]))
  end

  test "skips rebuildable and out_of_scope targets", %{src: src} do
    s =
      step([
        %{"name" => "influxdb", "path" => src, "tier" => "rebuildable"},
        %{"name" => "kratos", "path" => src, "tier" => "out_of_scope"}
      ])

    assert {:ok, handle} = BackupVerify.run(s, ctx())
    assert handle["verified"] == true
    assert handle["backups"] == []
  end

  test "is fail-closed: a missing preserve source errors the gate" do
    s = step([%{"name" => "gitlab", "path" => "/no/such/source", "tier" => "preserve"}])

    assert {:error, {:backup_verify_failed, "gitlab", {:source_missing, _}}} =
             BackupVerify.run(s, ctx())
  end

  test "compensate removes the backup root", %{src: src} do
    s = step([%{"name" => "pg", "path" => src, "tier" => "preserve"}])
    {:ok, handle} = BackupVerify.run(s, ctx())
    assert File.exists?(handle["root"])

    completed = %{id: 1, resource_handle: handle}
    assert :ok = BackupVerify.compensate(completed, ctx())
    refute File.exists?(handle["root"])
  end

  test "an empty target list passes the gate trivially" do
    assert {:ok, %{"verified" => true, "backups" => []}} = BackupVerify.run(step([]), ctx())
  end
end
