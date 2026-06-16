defmodule Homelab.Storage.Zfs.InMemoryTest do
  use ExUnit.Case, async: false

  alias Homelab.Storage.Zfs.InMemory

  setup do
    start_supervised!(InMemory)
    :ok
  end

  describe "pool operations" do
    test "creates and lists pools" do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{ashift: 12})
      {:ok, pools} = InMemory.list_pools()
      assert [%{name: "tank", health: :online}] = pools
    end

    test "rejects duplicate pool creation" do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      assert {:error, :pool_exists} = InMemory.create_pool("tank", ["/dev/fake1"], %{})
    end

    test "pool_status returns info for existing pool" do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      {:ok, info} = InMemory.pool_status("tank")
      assert info.name == "tank"
      assert info.health == :online
    end

    test "scrub_pool updates last_scrub_at" do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      assert :ok = InMemory.scrub_pool("tank")
      {:ok, info} = InMemory.pool_status("tank")
      assert %DateTime{} = info.last_scrub_at
    end
  end

  describe "dataset operations" do
    setup do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      :ok
    end

    test "creates nested datasets when parents exist" do
      assert :ok = InMemory.create_dataset("tank/appdata", %{})
      assert :ok = InMemory.create_dataset("tank/appdata/foo", %{})
      assert InMemory.dataset_exists?("tank/appdata/foo")
    end

    test "rejects dataset creation when parent missing" do
      assert {:error, :no_parent} = InMemory.create_dataset("tank/appdata/foo", %{})
    end

    test "rejects duplicate dataset" do
      :ok = InMemory.create_dataset("tank/appdata", %{})
      assert {:error, :already_exists} = InMemory.create_dataset("tank/appdata", %{})
    end

    test "lists datasets under parent" do
      :ok = InMemory.create_dataset("tank/appdata", %{})
      :ok = InMemory.create_dataset("tank/appdata/foo", %{})
      :ok = InMemory.create_dataset("tank/appdata/bar", %{})

      {:ok, list} = InMemory.list_datasets("tank/appdata")
      names = Enum.map(list, & &1.name) |> Enum.sort()
      assert "tank/appdata" in names
      assert "tank/appdata/foo" in names
      assert "tank/appdata/bar" in names
    end

    test "destroys non-recursive removes only the named dataset" do
      :ok = InMemory.create_dataset("tank/appdata", %{})
      :ok = InMemory.create_dataset("tank/appdata/foo", %{})

      assert :ok = InMemory.destroy_dataset("tank/appdata/foo", [])
      refute InMemory.dataset_exists?("tank/appdata/foo")
      assert InMemory.dataset_exists?("tank/appdata")
    end

    test "destroys recursive removes children too" do
      :ok = InMemory.create_dataset("tank/appdata", %{})
      :ok = InMemory.create_dataset("tank/appdata/foo", %{})
      :ok = InMemory.create_dataset("tank/appdata/bar", %{})

      assert :ok = InMemory.destroy_dataset("tank/appdata", recursive: true)
      refute InMemory.dataset_exists?("tank/appdata")
      refute InMemory.dataset_exists?("tank/appdata/foo")
      refute InMemory.dataset_exists?("tank/appdata/bar")
    end
  end

  describe "snapshot operations" do
    setup do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      :ok = InMemory.create_dataset("tank/appdata", %{})
      :ok
    end

    test "creates and lists snapshots" do
      assert {:ok, "tank/appdata@v1"} = InMemory.snapshot("tank/appdata", "v1")
      assert {:ok, "tank/appdata@v2"} = InMemory.snapshot("tank/appdata", "v2")

      {:ok, snaps} = InMemory.list_snapshots("tank/appdata")
      names = Enum.map(snaps, & &1.name) |> Enum.sort()
      assert names == ["tank/appdata@v1", "tank/appdata@v2"]
    end

    test "rejects snapshot of missing dataset" do
      assert {:error, :no_such_dataset} = InMemory.snapshot("tank/missing", "v1")
    end

    test "rejects duplicate snapshot" do
      :ok = InMemory.create_dataset("tank/appdata", %{}) |> elem_ok_or_already()
      {:ok, _} = InMemory.snapshot("tank/appdata", "v1")
      assert {:error, :already_exists} = InMemory.snapshot("tank/appdata", "v1")
    end

    test "clone creates a new dataset from a snapshot" do
      {:ok, snap} = InMemory.snapshot("tank/appdata", "v1")
      assert :ok = InMemory.clone(snap, "tank/restore-drills/appdata-1", %{})
      assert InMemory.dataset_exists?("tank/restore-drills/appdata-1")
    end

    test "destroying dataset recursively also destroys its snapshots" do
      {:ok, _} = InMemory.snapshot("tank/appdata", "v1")
      {:ok, _} = InMemory.snapshot("tank/appdata", "v2")

      :ok = InMemory.destroy_dataset("tank/appdata", recursive: true)
      {:ok, snaps} = InMemory.list_snapshots("tank/appdata")
      assert snaps == []
    end
  end

  describe "send/receive" do
    setup do
      :ok = InMemory.create_pool("tank", ["/dev/fake1"], %{})
      :ok = InMemory.create_dataset("tank/appdata", %{})
      :ok
    end

    test "send_stream returns chunks for an existing snapshot" do
      {:ok, snap} = InMemory.snapshot("tank/appdata", "v1")
      assert {:ok, chunks} = InMemory.send_stream(snap, raw: true)
      assert is_list(chunks)
    end

    test "receive_stream creates the target dataset" do
      assert :ok = InMemory.receive_stream("tank/replica/foo", ["chunk1", "chunk2"], [])
      assert InMemory.dataset_exists?("tank/replica/foo")
    end
  end

  describe "protocol_version" do
    test "returns {:ok, 1}" do
      assert {:ok, 1} = InMemory.protocol_version()
    end
  end

  # --- Helpers ---

  defp elem_ok_or_already(:ok), do: :ok
  defp elem_ok_or_already({:error, :already_exists}), do: :ok
end
