defmodule Homelab.Repo.Migrations.AddRuntimePrivilegesToAppTemplates do
  use Ecto.Migration

  # What the container is allowed to ask the KERNEL for.
  #
  # Nothing could express these before, so a whole class of app was undeployable
  # through the UI: a VPN client needs NET_ADMIN and /dev/net/tun, a Zigbee or Z-Wave
  # coordinator needs its USB dongle, and WireGuard needs
  # net.ipv4.conf.all.src_valid_mark. The compose importer read none of them either,
  # so importing such a stack produced a template that looked complete and deployed a
  # container that could not work.
  #
  # NULL is "inherit / none" rather than [] for the array columns, mirroring
  # command/entrypoint: a template that has never been given capabilities and one that
  # has had them deliberately cleared are the same thing at the TEMPLATE level, but the
  # deployment overrides that shadow these do need the distinction.
  def change do
    alter table(:app_templates) do
      add :capabilities_add, {:array, :string}
      add :capabilities_drop, {:array, :string}
      add :devices, {:array, :map}
      add :sysctls, :map
    end
  end
end
