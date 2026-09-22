defmodule Homelab.Networking.Domain do
  use Ecto.Schema
  import Ecto.Changeset

  schema "domains" do
    field :fqdn, :string

    field :exposure_mode, Ecto.Enum,
      values: [:private, :sso_protected, :public],
      default: :sso_protected

    field :tls_status, Ecto.Enum,
      values: [:pending, :active, :expired, :failed],
      default: :pending

    field :tls_expires_at, :utc_datetime

    # What the domain is ACTUALLY serving, from a TLS handshake, as distinct from the
    # `tls_status` lifecycle above. They disagree exactly when something is wrong:
    # Traefik reports a router as active while serving its self-signed default because
    # ACME failed, and a subdomain under a wildcard never needs a certificate of its
    # own so nothing ever moves it off `:pending`.
    #
    # `nil` means never observed, which is a third thing from any status here.
    field :tls_observed_status, Ecto.Enum,
      values: [:valid, :expiring, :expired, :self_signed, :name_mismatch, :unreachable]

    field :tls_matched_name, :string
    field :tls_issuer, :string
    field :tls_checked_at, :utc_datetime

    belongs_to :deployment, Homelab.Deployments.Deployment
    belongs_to :dns_zone, Homelab.Networking.DnsZone

    timestamps()
  end

  @required_fields ~w(fqdn deployment_id)a
  @optional_fields ~w(exposure_mode tls_status tls_expires_at dns_zone_id)a

  def changeset(domain, attrs) do
    domain
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:fqdn, ~r/^[a-z0-9][a-z0-9.-]+[a-z0-9]$/,
      message: "must be a valid fully qualified domain name"
    )
    |> foreign_key_constraint(:deployment_id)
    |> unique_constraint(:fqdn)
  end

  @observation_fields ~w(tls_observed_status tls_matched_name tls_issuer tls_checked_at)a

  @doc """
  Records what a TLS handshake found. Separate from `changeset/2` because these fields
  are written by the observer and never by a form — nothing an operator submits should
  be able to claim a certificate was seen.
  """
  def observation_changeset(domain, attrs) do
    domain
    |> cast(attrs, @observation_fields)
    |> validate_required([:tls_observed_status, :tls_checked_at])
  end
end
