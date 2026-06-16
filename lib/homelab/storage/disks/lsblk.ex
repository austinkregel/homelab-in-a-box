defmodule Homelab.Storage.Disks.Lsblk do
  @moduledoc """
  Production `Homelab.Storage.Disks` implementation. Calls the host agent
  to run `lsblk -J -b -O <device>` and `wipefs --noheadings -O ...` on the
  host. The BEAM container cannot see host devices directly.
  """

  @behaviour Homelab.Storage.Disks

  alias Homelab.Storage.Zfs.HostAgent

  @impl true
  def list_disks do
    case HostAgent.request("host.list_disks", %{}) do
      {:ok, %{"blockdevices" => devices}} when is_list(devices) ->
        {:ok,
         devices
         |> Enum.filter(fn d -> d["type"] in ["disk", nil] end)
         |> Enum.map(&normalize_disk/1)}

      {:ok, _other} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  @impl true
  def disk_signatures(path) when is_binary(path) do
    case HostAgent.request("host.disk_signatures", %{"path" => path}) do
      {:ok, %{"signatures" => sigs}} when is_list(sigs) ->
        {:ok, Enum.map(sigs, &normalize_signature/1)}

      {:ok, _} ->
        {:ok, []}

      {:error, _} = err ->
        err
    end
  end

  defp normalize_disk(d) do
    %{
      name: d["name"] || "",
      path: d["path"] || "/dev/" <> (d["name"] || ""),
      size_bytes: to_int(d["size"]),
      model: blank_to_nil(d["model"]),
      serial: blank_to_nil(d["serial"]),
      rotational?: truthy?(d["rota"]),
      removable?: truthy?(d["rm"]),
      partitions: d |> Map.get("children", []) |> Enum.map(&normalize_partition/1),
      mountpoints: List.wrap(d["mountpoints"] || d["mountpoint"]) |> Enum.reject(&is_nil/1)
    }
  end

  defp normalize_partition(p) do
    %{
      name: p["name"] || "",
      path: p["path"] || "/dev/" <> (p["name"] || ""),
      size_bytes: to_int(p["size"]),
      fstype: blank_to_nil(p["fstype"]),
      mountpoints: List.wrap(p["mountpoints"] || p["mountpoint"]) |> Enum.reject(&is_nil/1)
    }
  end

  defp normalize_signature(s) do
    %{
      offset: to_int(s["offset"]),
      type: s["type"] || s["TYPE"] || "unknown",
      label: blank_to_nil(s["label"] || s["LABEL"]),
      uuid: blank_to_nil(s["uuid"] || s["UUID"])
    }
  end

  defp to_int(nil), do: 0
  defp to_int(n) when is_integer(n), do: n

  defp to_int(n) when is_binary(n),
    do:
      case(Integer.parse(n),
        do: (
          {i, _} -> i
          :error -> 0
        )
      )

  defp to_int(_), do: 0

  defp blank_to_nil(nil), do: nil
  defp blank_to_nil(""), do: nil
  defp blank_to_nil(v) when is_binary(v), do: String.trim(v) |> nil_if_blank()
  defp blank_to_nil(v), do: v

  defp nil_if_blank(""), do: nil
  defp nil_if_blank(v), do: v

  defp truthy?(true), do: true
  defp truthy?("1"), do: true
  defp truthy?(1), do: true
  defp truthy?(_), do: false
end
