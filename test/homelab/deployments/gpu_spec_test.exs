defmodule Homelab.Deployments.GpuSpecTest do
  use ExUnit.Case, async: true

  import Ecto.Changeset

  alias Homelab.Deployments.GpuSpec

  defp changeset(limits) do
    {%{}, %{limits: :map}}
    |> cast(%{limits: limits}, [:limits])
    |> GpuSpec.validate_changeset(:limits)
  end

  defp errors(changeset), do: Enum.map(changeset.errors, fn {_f, {msg, _}} -> msg end)

  describe "parse/1" do
    test "no gpu key means no GPU" do
      assert GpuSpec.parse(%{"memory_mb" => 512}) == nil
      assert GpuSpec.parse(%{}) == nil
      assert GpuSpec.parse(nil) == nil
    end

    test "fills in the conventional defaults" do
      gpu = GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia"}})

      assert gpu.vendor == "nvidia"
      assert gpu.count == 1
      assert gpu.devices == "all"
      assert gpu.kind == "NVIDIA-GPU"
    end

    test "amd gets its own kind and env var" do
      gpu = GpuSpec.parse(%{"gpu" => %{"vendor" => "amd"}})

      assert gpu.kind == "AMD-GPU"
      assert GpuSpec.visible_devices_env(gpu) == {"AMD_VISIBLE_DEVICES", "all"}
    end

    test "an explicit kind is never overridden — it must match daemon.json byte-for-byte" do
      gpu = GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia", "kind" => "gpu"}})
      assert gpu.kind == "gpu"
    end

    test "an unknown vendor is not a GPU request at all" do
      assert GpuSpec.parse(%{"gpu" => %{"vendor" => "intel"}}) == nil
      assert GpuSpec.parse(%{"gpu" => %{}}) == nil
    end

    test "count arrives from a form as a string" do
      assert GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia", "count" => "2"}}).count == 2
    end
  end

  describe "devices" do
    test "all means every GPU" do
      gpu = GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia"}})

      refute GpuSpec.specific_devices?(gpu)
      assert GpuSpec.visible_devices_env(gpu) == {"NVIDIA_VISIBLE_DEVICES", "all"}
    end

    test "a device list is enumerated for the API" do
      gpu = GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia", "devices" => "0, 1"}})

      assert GpuSpec.specific_devices?(gpu)
      assert GpuSpec.device_ids(gpu) == ["0", "1"]
    end

    test "a uuid survives intact" do
      gpu =
        GpuSpec.parse(%{"gpu" => %{"vendor" => "nvidia", "devices" => "GPU-45cbf7b3-f919"}})

      assert GpuSpec.device_ids(gpu) == ["GPU-45cbf7b3-f919"]
    end
  end

  describe "validate_changeset/2" do
    test "accepts a well-formed request" do
      assert changeset(%{"gpu" => %{"vendor" => "nvidia", "count" => 1}}).valid?
    end

    test "no GPU is always valid" do
      assert changeset(%{"memory_mb" => 512}).valid?
    end

    test "rejects an unsupported vendor" do
      cs = changeset(%{"gpu" => %{"vendor" => "intel"}})

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "vendor must be one of"))
    end

    test "rejects a zero or negative count" do
      refute changeset(%{"gpu" => %{"vendor" => "amd", "count" => 0}}).valid?
      refute changeset(%{"gpu" => %{"vendor" => "amd", "count" => -1}}).valid?
    end

    test "rejects a resource kind Swarm could never match" do
      cs = changeset(%{"gpu" => %{"vendor" => "nvidia", "kind" => "NVIDIA GPU!"}})

      refute cs.valid?
      assert Enum.any?(errors(cs), &(&1 =~ "byte-for-byte"))
    end
  end
end
