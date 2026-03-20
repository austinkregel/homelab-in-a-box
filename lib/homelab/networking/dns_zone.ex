defmodule Homelab.Networking.DnsZone do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_zones" do
    field :name, :string
    field :provider, :string, default: "manual"
    field :provider_zone_id, :string

    field :sync_status, Ecto.Enum,
      values: [:synced, :pending, :error],
      default: :pending

    field :last_synced_at, :utc_datetime

    has_many :dns_records, Homelab.Networking.DnsRecord
    has_many :domains, Homelab.Networking.Domain

    timestamps()
  end

  @required_fields ~w(name)a
  @optional_fields ~w(provider provider_zone_id sync_status last_synced_at)a

  def changeset(zone, attrs) do
    zone
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:name, ~r/^[a-z0-9][a-z0-9.-]+[a-z0-9]$/,
      message: "must be a valid domain name"
    )
    |> unique_constraint(:name)
  end
end
