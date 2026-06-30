defmodule Homelab.Deployments.Release do
  @moduledoc """
  A saga aggregate that drives a single deployment from plan to running via an
  ordered list of compensatable `ReleaseStep`s, or rolls it back on failure.

  `lease_owner`/`lease_expires_at` mark a release as legitimately in-flight: the
  reconciler leaves leased releases alone and only intervenes once a lease has
  expired (resume or escalate).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [
    :planning,
    :provisioning,
    :running,
    :failed,
    :rolling_back,
    :rolled_back,
    :rollback_failed,
    :superseded
  ]

  @terminal_statuses [:running, :failed, :rolled_back, :rollback_failed, :superseded]
  @active_statuses [:planning, :provisioning, :rolling_back]

  schema "releases" do
    field :status, Ecto.Enum, values: @statuses, default: :planning
    field :lease_owner, :string
    field :lease_expires_at, :utc_datetime
    field :plan, :map, default: %{}
    field :error_message, :string

    belongs_to :tenant, Homelab.Tenants.Tenant
    belongs_to :app_template, Homelab.Catalog.AppTemplate
    belongs_to :deployment, Homelab.Deployments.Deployment

    has_many :steps, Homelab.Deployments.ReleaseStep, preload_order: [asc: :position]

    timestamps()
  end

  @doc "All release statuses."
  def statuses, do: @statuses

  @doc "Statuses from which no further progress happens."
  def terminal_statuses, do: @terminal_statuses

  @doc "Statuses that count as an in-flight release (one allowed per deployment)."
  def active_statuses, do: @active_statuses

  def terminal?(%__MODULE__{status: status}), do: status in @terminal_statuses

  @required_fields ~w(tenant_id app_template_id deployment_id)a
  @optional_fields ~w(status lease_owner lease_expires_at plan error_message)a

  def changeset(release, attrs) do
    release
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:tenant_id)
    |> foreign_key_constraint(:app_template_id)
    |> foreign_key_constraint(:deployment_id)
    |> unique_constraint(:deployment_id, name: :releases_one_active_per_deployment)
  end

  def status_changeset(release, status, opts \\ []) do
    attrs = %{status: status}

    # `:error` only sets when present; lease keys use fetch so callers can
    # explicitly pass nil to *clear* the lease (distinct from "not provided").
    attrs =
      if error = Keyword.get(opts, :error), do: Map.put(attrs, :error_message, error), else: attrs

    attrs = put_if_present(attrs, :lease_owner, Keyword.fetch(opts, :lease_owner))
    attrs = put_if_present(attrs, :lease_expires_at, Keyword.fetch(opts, :lease_expires_at))

    release
    |> cast(attrs, [:status, :error_message, :lease_owner, :lease_expires_at])
    |> validate_inclusion(:status, @statuses)
  end

  defp put_if_present(attrs, key, {:ok, value}), do: Map.put(attrs, key, value)
  defp put_if_present(attrs, _key, :error), do: attrs
end
