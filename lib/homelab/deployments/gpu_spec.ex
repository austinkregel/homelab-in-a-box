defmodule Homelab.Deployments.GpuSpec do
  @moduledoc """
  A deployment's GPU request, and the vendor-specific facts needed to satisfy it.

  Stored under `resource_limits["gpu"]` — a GPU *is* a resource reservation, and
  `resource_limits` is already a free-form map on both `AppTemplate` and
  `Deployment`, so this needs no migration.

  ## Why the two orchestrators cannot share a mechanism

  **Docker Engine** passes devices directly: NVIDIA via `HostConfig.DeviceRequests`
  (the `nvidia` driver, negotiated with the container toolkit), AMD/ROCm via plain
  `HostConfig.Devices` on `/dev/kfd` + `/dev/dri`.

  **Docker Swarm cannot pass devices at all.** `--device`/`DeviceRequests` are
  rejected in swarm mode, and the device-support proposal (moby/swarmkit#2682) has
  been open since 2018 and is explicitly not on the road map. A swarm service gets
  a GPU only by:

    1. the node advertising it in `daemon.json` as a **generic resource**
       (`"node-generic-resources": ["NVIDIA-GPU=GPU-<uuid>"]`),
    2. the service **reserving** that resource, which is scheduling only — it picks
       the node, it does not put a device in the container, and
    3. a vendor **runtime hook** set as the node's `default-runtime`
       (`nvidia-container-runtime` / `amd-container-runtime`) doing the injection,
       driven by the visible-devices env var.

  All three must line up. If they do not, Swarm does not fail — the task sits
  `pending` forever with no error, or it starts with no GPU inside. Hence `kind`
  being explicit here, and `Homelab.Infrastructure.GpuFacts` checking it against
  what the cluster actually advertises before we deploy.

  ## Shape

      %{
        "vendor"  => "nvidia" | "amd",
        "count"   => 1,             # how many GPUs to RESERVE (Swarm scheduling)
        "devices" => "all",         # which GPUs to EXPOSE ("all" | "0,1" | "GPU-<uuid>")
        "kind"    => "NVIDIA-GPU"   # Swarm generic-resource kind; MUST match daemon.json
      }

  `count` and `devices` answer different questions and are both needed: Swarm
  schedules on the count and the runtime hook injects on the devices.
  """

  import Ecto.Changeset

  @vendors ~w(nvidia amd)

  # The conventional resource kinds. They are only conventions -- the node operator
  # picks the string in daemon.json, and Swarm matches it byte-for-byte -- so `kind`
  # stays overridable and GpuFacts offers what the cluster really advertises.
  @default_kinds %{"nvidia" => "NVIDIA-GPU", "amd" => "AMD-GPU"}

  # The env var each vendor's runtime hook reads to decide which GPUs to inject.
  @visible_devices_env %{
    "nvidia" => "NVIDIA_VISIBLE_DEVICES",
    "amd" => "AMD_VISIBLE_DEVICES"
  }

  @max_count 64

  @doc "The GPU request in a resource-limits map, normalized — or nil if there is none."
  def parse(limits) when is_map(limits), do: normalize(Map.get(limits, "gpu"))
  def parse(_limits), do: nil

  @doc "Normalizes one raw GPU map. Returns nil for anything that is not a valid request."
  def normalize(%{} = gpu) do
    vendor = gpu |> Map.get("vendor") |> to_string() |> String.downcase()

    if vendor in @vendors do
      %{
        vendor: vendor,
        count: count(Map.get(gpu, "count")),
        devices: blank_to_nil(Map.get(gpu, "devices")) || "all",
        kind: blank_to_nil(Map.get(gpu, "kind")) || @default_kinds[vendor]
      }
    end
  end

  def normalize(_gpu), do: nil

  @doc "All supported vendors."
  def vendors, do: @vendors

  @doc "The conventional Swarm generic-resource kind for a vendor."
  def default_kind(vendor), do: Map.get(@default_kinds, to_string(vendor))

  @doc """
  The `{env_var, value}` the vendor runtime hook reads to decide which GPUs to inject
  into the container. Set on the spec's env by `SpecBuilder`, BEFORE the operator's
  env overrides, so an operator can still pin a specific device by hand.
  """
  def visible_devices_env(%{vendor: vendor, devices: devices}),
    do: {Map.fetch!(@visible_devices_env, vendor), devices}

  @doc "True when the request names specific devices rather than every GPU on the node."
  def specific_devices?(%{devices: devices}), do: devices != "all"

  @doc "The device ids as a list, for an API that wants them enumerated."
  def device_ids(%{devices: devices}) do
    devices
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  @doc """
  Validates the `"gpu"` entry of a resource-limits field on a changeset.

  Refuses rather than repairs. A GPU request that is wrong in any of these ways does
  not fail loudly at deploy — under Swarm it hangs `pending`, and under Engine it can
  start with no GPU and only surface as an inference error hours later.
  """
  def validate_changeset(changeset, field) do
    case get_change(changeset, field) do
      nil -> changeset
      limits when is_map(limits) -> validate_gpu(changeset, field, Map.get(limits, "gpu"))
      _ -> changeset
    end
  end

  defp validate_gpu(changeset, _field, nil), do: changeset

  defp validate_gpu(changeset, field, gpu) when is_map(gpu) do
    vendor = gpu |> Map.get("vendor") |> to_string() |> String.downcase()
    raw_count = Map.get(gpu, "count")

    cond do
      vendor not in @vendors ->
        add_error(changeset, field, "GPU vendor must be one of: #{Enum.join(@vendors, ", ")}")

      not valid_count?(raw_count) ->
        add_error(changeset, field, "GPU count must be a whole number from 1 to #{@max_count}")

      not valid_kind?(Map.get(gpu, "kind")) ->
        add_error(
          changeset,
          field,
          "the Swarm resource kind must match the node's daemon.json byte-for-byte " <>
            "(letters, digits, dot, dash, underscore)"
        )

      true ->
        changeset
    end
  end

  defp validate_gpu(changeset, field, _gpu),
    do: add_error(changeset, field, "the GPU request must be a map")

  defp valid_count?(nil), do: true
  defp valid_count?(count) when is_integer(count), do: count >= 1 and count <= @max_count

  defp valid_count?(count) when is_binary(count) do
    case Integer.parse(String.trim(count)) do
      {n, ""} -> n >= 1 and n <= @max_count
      _ -> String.trim(count) == ""
    end
  end

  defp valid_count?(_count), do: false

  defp valid_kind?(nil), do: true
  defp valid_kind?(""), do: true
  defp valid_kind?(kind) when is_binary(kind), do: Regex.match?(~r/^[A-Za-z0-9_.-]+$/, kind)
  defp valid_kind?(_kind), do: false

  defp count(nil), do: 1
  defp count(n) when is_integer(n) and n >= 1, do: min(n, @max_count)

  defp count(n) when is_binary(n) do
    case Integer.parse(String.trim(n)) do
      {parsed, ""} when parsed >= 1 -> min(parsed, @max_count)
      _ -> 1
    end
  end

  defp count(_n), do: 1

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil
end
