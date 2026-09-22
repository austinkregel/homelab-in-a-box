defmodule Homelab.Repo.Migrations.AddTlsObservationsToDomains do
  use Ecto.Migration

  # What each domain is ACTUALLY serving, recorded from a TLS handshake.
  #
  # Deliberately beside `tls_status` rather than folded into it. That column is the
  # lifecycle CertManager intends — pending, active, expired, failed — and
  # `list_pending_tls/0` and `list_expiring_tls/1` drive the renewal loop off its
  # values, so adding "is serving Traefik's default cert" to that enum would drop those
  # domains out of the retry queue. Intent and observation are two different facts and
  # they disagree precisely when something is wrong, which is when the page matters.
  def change do
    alter table(:domains) do
      # nil means never observed. Distinct from every observed value: a domain nobody
      # has looked at yet is not the same claim as one confirmed healthy.
      add :tls_observed_status, :string
      # Which name on the certificate covered this domain — "*.homelab.example.com" for
      # the wildcard case, the fqdn itself for a certificate of its own. This is the
      # answer to "why is a domain nobody requested a certificate for served over TLS".
      add :tls_matched_name, :string
      add :tls_issuer, :string
      # Without this a stored status cannot be presented honestly: "Valid" six hours old
      # and "Valid" three weeks old are not the same claim.
      add :tls_checked_at, :utc_datetime
    end

    create index(:domains, [:tls_checked_at])
  end
end
