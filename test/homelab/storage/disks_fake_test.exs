defmodule Homelab.Storage.Disks.FakeTest do
  use ExUnit.Case, async: false

  alias Homelab.Storage.Disks.Fake

  setup do
    start_supervised!(Fake)
    :ok
  end

  test "list_disks starts empty" do
    assert {:ok, []} = Fake.list_disks()
  end

  test "add_disk + list_disks round-trips a disk" do
    Fake.add_disk(%{
      name: "sdb",
      path: "/dev/sdb",
      size_bytes: 1_000_000_000_000,
      model: "Fake Drive",
      serial: "ABC123",
      rotational?: false,
      removable?: false,
      partitions: [],
      mountpoints: []
    })

    assert {:ok, [disk]} = Fake.list_disks()
    assert disk.path == "/dev/sdb"
    assert disk.size_bytes == 1_000_000_000_000
  end

  test "disk_signatures starts empty for unknown path" do
    assert {:ok, []} = Fake.disk_signatures("/dev/nowhere")
  end

  test "set_signatures + disk_signatures round-trip" do
    Fake.set_signatures("/dev/sdb", [%{offset: 0, type: "ext4", label: "old", uuid: "u-1"}])

    assert {:ok, [%{type: "ext4", label: "old"}]} = Fake.disk_signatures("/dev/sdb")
  end

  test "wipe clears signatures" do
    Fake.set_signatures("/dev/sdb", [%{offset: 0, type: "ext4", label: nil, uuid: nil}])
    Fake.wipe("/dev/sdb")
    assert {:ok, []} = Fake.disk_signatures("/dev/sdb")
  end
end
