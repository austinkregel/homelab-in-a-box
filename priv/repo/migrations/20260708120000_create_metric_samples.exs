defmodule Homelab.Repo.Migrations.CreateMetricSamples do
  @moduledoc """
  Time-series store for host, Docker, and reverse-proxy telemetry.

  The base table is plain PostgreSQL so it works everywhere (CI, a stock
  self-hosted Postgres). When the TimescaleDB extension is available on the
  server we upgrade it to a hypertable for chunked, time-partitioned storage;
  otherwise a BRIN index on the time column keeps range scans cheap on the flat
  table. Either way the columns are identical, so application code is agnostic
  to which shape it got.
  """
  use Ecto.Migration

  def up do
    create table(:metric_samples, primary_key: false) do
      add :recorded_at, :utc_datetime_usec, null: false
      # e.g. "host", "docker", "traefik"
      add :source, :string, null: false
      # dimension within a source: a mount path, a service/router name, nil for
      # host-wide series.
      add :subject, :string
      # e.g. "cpu_percent", "memory_percent", "disk_percent", "requests_total"
      add :metric, :string, null: false
      add :value, :float, null: false
    end

    # Range scans over time are the dominant query; BRIN is tiny and ideal for
    # append-only, roughly time-ordered rows.
    create index(:metric_samples, [:recorded_at], using: "brin")
    # Point lookups for one series (a single metric of a single subject over time).
    create index(:metric_samples, [:source, :subject, :metric, :recorded_at])

    maybe_enable_hypertable()
  end

  def down do
    drop table(:metric_samples)
  end

  # Turn the table into a TimescaleDB hypertable when the extension is installed
  # on this server. On stock PostgreSQL (CI, most self-host setups) this is a
  # no-op and the flat table + BRIN index is used as-is.
  defp maybe_enable_hypertable do
    if timescaledb_available?() do
      execute("CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE")

      execute("SELECT create_hypertable('metric_samples', 'recorded_at', if_not_exists => TRUE)")
    end
  end

  defp timescaledb_available? do
    %{rows: rows} =
      repo().query!("SELECT 1 FROM pg_available_extensions WHERE name = 'timescaledb' LIMIT 1")

    rows != []
  end
end
