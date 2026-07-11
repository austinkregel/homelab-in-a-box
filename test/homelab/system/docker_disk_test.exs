defmodule Homelab.System.DockerDiskTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.System.DockerDisk

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  # Trimmed shape of a real `GET /system/df` response.
  @system_df %{
    "LayersSize" => 5_000_000_000,
    "Images" => [
      %{"Size" => 3_000_000_000},
      %{"Size" => 2_000_000_000}
    ],
    "Containers" => [
      %{"SizeRw" => 100_000, "SizeRootFs" => 900_000}
    ],
    "Volumes" => [
      %{"Name" => "app_pgdata", "UsageData" => %{"Size" => 1_000_000_000, "RefCount" => 1}},
      %{"Name" => "old_cache", "UsageData" => %{"Size" => 500_000_000, "RefCount" => 0}},
      %{"Name" => "unknown_size", "UsageData" => %{"Size" => -1, "RefCount" => 1}}
    ],
    "BuildCache" => [%{"Size" => 250_000_000}, %{"Size" => 250_000_000}]
  }

  describe "parse/1" do
    test "summarizes volumes, images, containers, and build cache" do
      s = DockerDisk.parse(@system_df)

      # -1 (uncomputable) volume is dropped; two remain, size-sorted desc.
      assert Enum.map(s.volumes.items, & &1.name) == ["app_pgdata", "old_cache"]
      assert s.volumes.count == 2
      assert s.volumes.size == 1_500_000_000
      assert s.volumes.active == 1
      assert s.volumes.reclaimable == 500_000_000

      assert Enum.find(s.volumes.items, &(&1.name == "app_pgdata")).in_use == true
      assert Enum.find(s.volumes.items, &(&1.name == "old_cache")).in_use == false

      assert s.images == %{count: 2, size: 5_000_000_000}
      assert s.containers == %{count: 1, size: 1_000_000}
      assert s.build_cache == %{size: 500_000_000}
    end

    test "tolerates a response missing keys" do
      s = DockerDisk.parse(%{})

      assert s.volumes == %{count: 0, size: 0, active: 0, reclaimable: 0, items: []}
      assert s.images == %{count: 0, size: 0}
      assert s.build_cache == %{size: 0}
    end
  end

  describe "collect/0" do
    test "fetches /system/df and returns a parsed summary" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/system/df", opts ->
        assert Keyword.has_key?(opts, :receive_timeout)
        {:ok, @system_df}
      end)

      assert {:ok, summary} = DockerDisk.collect()
      assert summary.volumes.count == 2
    end

    test "returns an error when the daemon is unreachable" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/system/df", _opts ->
        {:error, {:connection_error, :econnrefused}}
      end)

      assert {:error, {:connection_error, :econnrefused}} = DockerDisk.collect()
    end

    test "returns an error on a non-map body" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/system/df", _opts -> {:ok, "nope"} end)
      assert {:error, {:unexpected_body, "nope"}} = DockerDisk.collect()
    end
  end
end
