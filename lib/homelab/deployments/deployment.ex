defmodule Homelab.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :deploying, :running, :failed, :stopped, :removing]

  schema "deployments" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :external_id, :string
    field :domain, :string
    field :env_overrides, :map, default: %{}
    field :computed_spec, :map
    field :last_reconciled_at, :utc_datetime
    field :error_message, :string

    belongs_to :tenant, Homelab.Tenants.Tenant
    belongs_to :app_template, Homelab.Catalog.AppTemplate

    has_many :domains, Homelab.Networking.Domain
    has_many :dns_records, Homelab.Networking.DnsRecord
    has_many :backup_jobs, Homelab.Backups.BackupJob

    timestamps()
  end

  @required_fields ~w(tenant_id app_template_id)a
  @optional_fields ~w(status external_id domain env_overrides computed_spec
                      last_reconciled_at error_message)a

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:app_template_id)
    |> unique_constraint([:tenant_id, :app_template_id])
  end

  def status_changeset(deployment, status, opts \\ []) do
    attrs = %{status: status}

    attrs =
      if error = Keyword.get(opts, :error), do: Map.put(attrs, :error_message, error), else: attrs

    attrs =
      if ext_id = Keyword.get(opts, :external_id),
        do: Map.put(attrs, :external_id, ext_id),
        else: attrs

    deployment
    |> cast(attrs, [:status, :error_message, :external_id])
    |> validate_inclusion(:status, @statuses)
  end

  def reconciled_changeset(deployment) do
    deployment
    |> cast(%{last_reconciled_at: DateTime.utc_now()}, [:last_reconciled_at])
  end
end
