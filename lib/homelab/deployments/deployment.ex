defmodule Homelab.Deployments.Deployment do
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :deploying, :running, :failed, :stopped, :removing]
  # Same set as AppTemplate.exposure_mode; stored as a string override here so a
  # single deployment can diverge from the (shared) template default.
  @exposure_modes ~w(private sso_protected public service host)

  schema "deployments" do
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :external_id, :string
    field :domain, :string
    field :env_overrides, :map, default: %{}
    # Per-deployment overrides (nil = inherit the app_template default).
    field :ports_override, {:array, :map}
    field :exposure_mode_override, :string
    field :resource_limits_override, :map
    field :health_check_override, :map
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
  @optional_fields ~w(status external_id domain env_overrides ports_override
                      exposure_mode_override resource_limits_override
                      health_check_override computed_spec last_reconciled_at
                      error_message)a

  def changeset(deployment, attrs) do
    deployment
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> validate_inclusion(:exposure_mode_override, @exposure_modes)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:app_template_id)
    |> unique_constraint([:tenant_id, :app_template_id])
  end

  @doc "All valid exposure-mode override values (strings)."
  def exposure_modes, do: @exposure_modes

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
