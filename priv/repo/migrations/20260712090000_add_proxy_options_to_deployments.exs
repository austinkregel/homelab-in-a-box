defmodule Homelab.Repo.Migrations.AddProxyOptionsToDeployments do
  use Ecto.Migration

  # Reverse-proxy options that are not a port, a domain, or an exposure mode.
  # Currently: sticky sessions, which pin a client to one replica so a websocket
  # (or LiveView) reconnect does not land on a different container.
  def change do
    alter table(:deployments) do
      add :proxy_options, :map, default: %{}, null: false
    end
  end
end
