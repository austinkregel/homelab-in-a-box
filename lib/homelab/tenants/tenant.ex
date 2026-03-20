defmodule Homelab.Tenants.Tenant do
  use Ecto.Schema
  import Ecto.Changeset

  schema "tenants" do
    field :name, :string
    field :slug, :string
    field :status, Ecto.Enum, values: [:active, :suspended, :archived], default: :active
    field :settings, :map, default: %{}

    has_many :deployments, Homelab.Deployments.Deployment

    timestamps()
  end

  @required_fields ~w(name slug)a
  @optional_fields ~w(status settings)a

  def changeset(tenant, attrs) do
    tenant
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_format(:slug, ~r/^[a-z0-9][a-z0-9-]*[a-z0-9]$/,
      message: "must be lowercase alphanumeric with hyphens, not starting or ending with a hyphen"
    )
    |> validate_length(:slug, min: 2, max: 63)
    |> validate_length(:name, min: 1, max: 255)
    |> validate_inclusion(:status, [:active, :suspended, :archived])
    |> unique_constraint(:slug)
  end
end
