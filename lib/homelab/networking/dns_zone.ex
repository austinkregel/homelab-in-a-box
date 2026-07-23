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

  @doc """
  Changeset for editing an existing zone.

  A zone had no edit path at all, so moving one from `manual` to `cloudflare` meant
  deleting it and cascading away every record it held — for what is really a change of
  who answers for the same names.

  `name` is deliberately not castable here: the records and domains hanging off this
  zone are all scoped to that name, so renaming it is a migration rather than an edit.

  Changing the provider resets `sync_status` to `:pending`, because what the previous
  provider had published says nothing about the new one — but only when the caller did
  not state a status itself. The registrar sync changes the provider and knows the
  result is synced; an operator editing the form in the UI does not.
  """
  def update_changeset(zone, attrs) do
    zone
    |> cast(attrs, @optional_fields)
    |> reset_sync_on_provider_change(zone)
  end

  defp reset_sync_on_provider_change(changeset, zone) do
    provider_moved? =
      case get_change(changeset, :provider) do
        nil -> false
        provider -> provider != zone.provider
      end

    if provider_moved? and get_change(changeset, :sync_status) == nil do
      changeset
      |> put_change(:sync_status, :pending)
      |> put_change(:last_synced_at, nil)
    else
      changeset
    end
  end
end
