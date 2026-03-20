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
end
