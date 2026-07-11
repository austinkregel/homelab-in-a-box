defmodule Homelab.System.MetricsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.System.Metrics

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  # `collect/0` calls `collect_docker_info`, which runs the `/info` GET
  # *synchronously in the caller* (see Metrics.collect/0 -> collect_docker_info/0),
  # so the Mox expectation set here is observed by the code under test.
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "collect/0" do
    test "returns a map with expected keys" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)

      result = Metrics.collect()

      assert is_map(result)
      assert Map.has_key?(result, :cpu_percent)
      assert Map.has_key?(result, :memory_total)
      assert Map.has_key?(result, :memory_used)
      assert Map.has_key?(result, :memory_percent)
      assert Map.has_key?(result, :disk)
      assert Map.has_key?(result, :docker)
    end

    test "returns numeric cpu_percent" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_number(result.cpu_percent)
    end

    test "returns numeric memory values" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_integer(result.memory_total) or result.memory_total == 0
      assert is_integer(result.memory_used) or result.memory_used == 0
      assert is_number(result.memory_percent)
    end

    test "returns disk as a list" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_list(result.disk)
    end

    test "returns docker as a map" do
      stub(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, %{}} end)
      result = Metrics.collect()
      assert is_map(result.docker)
    end
  end

  describe "collect/0 docker info (mocked daemon)" do
    test "GETs /info and passes the daemon-info body through unchanged" do
      info = %{
        "ID" => "ABCD:EFGH",
        "Containers" => 7,
        "ContainersRunning" => 5,
        "ContainersPaused" => 0,
        "ContainersStopped" => 2,
        "Images" => 12,
        "ServerVersion" => "25.0.3",
        "OperatingSystem" => "Ubuntu 24.04",
        "NCPU" => 8,
        "MemTotal" => 16_000_000_000
      }

      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, info} end)

      result = Metrics.collect()

      # The collector is a pure passthrough for a map body: same map, verbatim.
      assert result.docker == info
      assert result.docker["ServerVersion"] == "25.0.3"
      assert result.docker["ContainersRunning"] == 5
    end

    test "GETs exactly the /info path (no extra query/segments)" do
      test_pid = self()

      expect(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        send(test_pid, {:docker_get, path})
        {:ok, %{"ID" => "x"}}
      end)

      Metrics.collect()

      assert_received {:docker_get, "/info"}
    end

    test "falls back to an empty map when the daemon is unreachable" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts ->
        {:error, {:connection_error, :econnrefused}}
      end)

      result = Metrics.collect()

      assert result.docker == %{}
    end

    test "falls back to an empty map on an HTTP error tuple" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      assert Metrics.collect().docker == %{}
    end

    test "falls back to an empty map when the body is not a map" do
      # The guard is `{:ok, info} when is_map(info)`; a non-map :ok body must not
      # leak through as the docker field.
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> {:ok, "not-a-map"} end)

      assert Metrics.collect().docker == %{}
    end

    test "falls back to an empty map on an unexpected return shape" do
      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _opts -> :unexpected end)

      assert Metrics.collect().docker == %{}
    end
  end

  describe "parse_disk_output/1" do
    test "keeps root + operator-passed disks from Linux container df output" do
      # Captured from `df -Pk` inside the app's Alpine container: overlay root,
      # the dev source bind-mounts (/app/*), Docker-injected /etc files, pseudo-fs,
      # and a physical disk the operator passed in via HOMELAB_DISKS (-> /mnt/tank).
      output = """
      Filesystem           1024-blocks      Used Available Capacity Mounted on
      overlay                 73734136  40000000  33734136      55% /
      tmpfs                      65536         0     65536       0% /dev
      shm                        65536         0     65536       0% /dev/shm
      /run/host_mark/Users   971350180 480000000 491350180      50% /app/lib
      /run/host_mark/Users   971350180 480000000 491350180      50% /app/config
      /dev/sdb1             3906899456 1600000000 2306899456      41% /mnt/tank
      /dev/vda1               73734136  40000000  33734136      55% /etc/resolv.conf
      /dev/vda1               73734136  40000000  33734136      55% /etc/hostname
      /dev/vda1               73734136  40000000  33734136      55% /etc/hosts
      proc                           0         0         0       0% /proc/scsi
      sysfs                          0         0         0       0% /sys/firmware
      """

      mounts = Metrics.parse_disk_output(output) |> Enum.map(& &1.mount)

      # overlay '/' (the host root disk) plus the passed-in physical disk; the
      # dev-only /app/* source mounts, /etc files, and pseudo-fs are dropped.
      assert mounts == ["/", "/mnt/tank"]
    end

    test "keeps only real disks from macOS df output" do
      # Captured from `df -Pk` on macOS (APFS): every /System/Volumes/* is a
      # distinct device sharing the physical disk, plus devfs and a NAS mount.
      output = """
      Filesystem            1024-blocks       Used Available Capacity  Mounted on
      /dev/disk3s1s1          971350180   17000000 453000000     4%    /
      devfs                         208        208         0   100%    /dev
      /dev/disk3s6            971350180    2000000 453000000     1%    /System/Volumes/VM
      /dev/disk3s2            971350180     500000 453000000     1%    /System/Volumes/Preboot
      /dev/disk3s5            971350180  480000000 453000000    52%    /System/Volumes/Data
      /dev/disk7s1              2252800     100000   2152800     5%    /private/var/run/x
      //user@nas/Archives   37479965000 20000000000 17479965000  54%   /Volumes/Archives
      """

      mounts = Metrics.parse_disk_output(output) |> Enum.map(& &1.mount)

      # Only the real root and the network share survive.
      assert mounts == ["/", "/Volumes/Archives"]
    end

    test "computes percent and converts 1K-blocks to bytes" do
      output = """
      Filesystem 1024-blocks    Used Available Capacity Mounted on
      /dev/sda1     1000000  250000    750000      25% /
      """

      assert [disk] = Metrics.parse_disk_output(output)
      assert disk.mount == "/"
      assert disk.total == 1_000_000 * 1024
      assert disk.used == 250_000 * 1024
      assert_in_delta disk.percent, 25.0, 0.01
      refute Map.has_key?(disk, :fs)
    end

    test "drops zero-capacity rows and survives malformed lines" do
      output = """
      Filesystem 1024-blocks Used Available Capacity Mounted on
      map auto_home                                  100% /System/Volumes/Data/home
      tmpfs                0    0        0    0% /run/lock
      garbage line without enough columns
      /dev/sda1      1000000 500000  500000   50% /data
      """

      assert Metrics.parse_disk_output(output) |> Enum.map(& &1.mount) == ["/data"]
    end
  end
end
