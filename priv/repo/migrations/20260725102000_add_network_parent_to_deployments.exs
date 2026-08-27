defmodule Homelab.Repo.Migrations.AddNetworkParentToDeployments do
  use Ecto.Migration

  # Which deployment's NETWORK NAMESPACE this one lives in (NULL = its own).
  #
  # This is the shape every VPN'd stack has: gluetun holds the only egress path, and
  # the apps behind it have no network stack of their own at all
  # (`network_mode: service:gluetun` in compose, `--network container:<id>` to the
  # daemon). Nothing could express it before — `host_network` was the only namespace
  # sharing, and it shares with the HOST, which is the opposite of what a tunnel is for.
  #
  # `on_delete: :restrict` rather than :nilify. A child cannot survive losing its donor:
  # its NetworkMode still names a container id that no longer exists, so the daemon
  # refuses to start it ("cannot join network of a non running container"). Nilifying
  # would quietly reattach it to the tenant network — outside the tunnel — which for a
  # VPN'd app is a traffic leak, not a degraded state. The delete is refused instead,
  # and Deployments.delete_deployment/1 says why.
  def change do
    alter table(:deployments) do
      add :network_parent_id, references(:deployments, on_delete: :restrict)
    end

    create index(:deployments, [:network_parent_id])
  end
end
