defmodule Homelab.Storage.Disks do
  @moduledoc """
  Behaviour for host disk enumeration and signature inspection.

  The Storage UI (decision §3) lets the operator pick a disk for pool
  creation. Before a destructive `zpool create`, we must report whether the
  disk has any partition table or filesystem signature so the user can
  decide whether to wipe it. All operations route through the host agent
  (decision §1) because the BEAM container can't see host devices.

  Implementations:

    * `Homelab.Storage.Disks.Lsblk` — production; calls `lsblk -J` /
      `wipefs --noheadings -O` via the host agent.
    * `Homelab.Storage.Disks.Fake` — tests; in-process state.
  """

  @type disk :: %{
          name: String.t(),
          path: String.t(),
          size_bytes: non_neg_integer(),
          model: String.t() | nil,
          serial: String.t() | nil,
          rotational?: boolean(),
          removable?: boolean(),
          partitions: [partition()],
          mountpoints: [String.t()]
        }

  @type partition :: %{
          name: String.t(),
          path: String.t(),
          size_bytes: non_neg_integer(),
          fstype: String.t() | nil,
          mountpoints: [String.t()]
        }

  @type signature :: %{
          offset: non_neg_integer(),
          type: String.t(),
          label: String.t() | nil,
          uuid: String.t() | nil
        }

  @callback list_disks() :: {:ok, [disk()]} | {:error, term()}
  @callback disk_signatures(path :: String.t()) :: {:ok, [signature()]} | {:error, term()}

  @spec impl() :: module()
  def impl, do: Application.get_env(:homelab, :disks_impl, Homelab.Storage.Disks.Lsblk)
end
