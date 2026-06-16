defmodule Homelab.Storage.ImplResolutionTest do
  use ExUnit.Case, async: false

  test "Homelab.Storage.Zfs.impl/0 resolves to the Mox mock in test env" do
    assert Homelab.Storage.Zfs.impl() == Homelab.Mocks.Storage.Zfs
  end

  test "Homelab.Storage.Disks.impl/0 resolves to the Mox mock in test env" do
    assert Homelab.Storage.Disks.impl() == Homelab.Mocks.Storage.Disks
  end

  test "Homelab.BackupProviders.Restic.Driver.impl/0 resolves to the Mox mock in test env" do
    assert Homelab.BackupProviders.Restic.Driver.impl() == Homelab.Mocks.Restic.Driver
  end

  test "impl/0 falls back to the configured default when app env unset" do
    saved = Application.get_env(:homelab, :zfs_impl)
    Application.delete_env(:homelab, :zfs_impl)

    try do
      assert Homelab.Storage.Zfs.impl() == Homelab.Storage.Zfs.HostAgent
    after
      Application.put_env(:homelab, :zfs_impl, saved)
    end
  end
end
