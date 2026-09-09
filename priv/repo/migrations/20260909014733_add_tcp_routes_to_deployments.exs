defmodule Homelab.Repo.Migrations.AddTcpRoutesToDeployments do
  use Ecto.Migration

  # Hostname-addressed TCP endpoints for one deployment -- how a datastore becomes
  # reachable as `postgres-media.example.com` instead of a published host port.
  #
  # `domain`, `extra_routes` and `additional_domains` all describe HTTP routers, which
  # is the only kind of router this system emitted until now. A database speaks its own
  # wire protocol, so an HTTP router in front of it parses the startup packet as a
  # request and drops the connection; no `backend_scheme` value changes that. A Traefik
  # TCP router matches on the TLS SNI name instead and forwards bytes, which is the
  # shape a database connection actually needs.
  #
  # Each entry: %{"host" => "postgres-media.example.com", "port" => 5432,
  # "source_range" => "10.0.0.0/8,192.168.1.0/24"}. `source_range` is required only for
  # `:private` deployments and carries explicit CIDRs -- see the TCP section of
  # `SpecBuilder` for why the RFC1918 default the HTTP path uses is not safe here.
  #
  # No entrypoint field: `websecure` is the only entrypoint these can ride today, so
  # storing it would be a column with one legal value.
  def change do
    alter table(:deployments) do
      add :tcp_routes, {:array, :map}, default: [], null: false
    end
  end
end
