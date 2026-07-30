defmodule Homelab.Networking.DnsRecord do
  use Ecto.Schema
  import Ecto.Changeset

  schema "dns_records" do
    field :name, :string
    field :type, :string
    field :value, :string
    field :ttl, :integer, default: 300

    field :scope, Ecto.Enum,
      values: [:public, :internal, :both],
      default: :public

    field :provider_record_id, :string
    field :managed, :boolean, default: true

    # Whether this record actually reached its provider. Every provider failure used to
    # be swallowed into `:ok` and reported as success, and there was no field that could
    # say otherwise — a record that never left the box looked exactly like one serving
    # traffic. nil on both means "never attempted, or written before this existed".
    field :last_synced_at, :utc_datetime
    field :last_sync_error, :string

    belongs_to :dns_zone, Homelab.Networking.DnsZone
    belongs_to :deployment, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(name type value dns_zone_id)a
  @optional_fields ~w(ttl scope provider_record_id managed deployment_id
                      last_synced_at last_sync_error)a

  def changeset(record, attrs) do
    record
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, ~w(A AAAA CNAME MX TXT SRV NS))
    |> validate_number(:ttl, greater_than: 0)
    |> foreign_key_constraint(:dns_zone_id)
    |> foreign_key_constraint(:deployment_id)
  end
end
