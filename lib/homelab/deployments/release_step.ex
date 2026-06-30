defmodule Homelab.Deployments.ReleaseStep do
  @moduledoc """
  One ordered, typed, compensatable step in a `Release`.

  `position` defines the strict execution order (lower runs first); compensation
  walks completed steps in descending `position`. `resource_handle` records what
  the step created (a container `external_id`, a network name, a secret id, …) so
  the step's compensation can undo it idempotently without re-deriving anything.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @types [
    # Greenfield deploy steps.
    :network,
    :provision_credentials,
    :dependency_container,
    :await_health,
    :app_container,
    :publish_ingress,
    # Adoption steps (taking over an existing stack in place). `:backup_verify`
    # is the fail-closed gate; `:adopt_credentials` imports existing secrets
    # rather than generating; `:quiesce_old` stops the old container (and
    # disables its restart policy) before a single-writer cutover;
    # `:adopt_volume`/`:adopt_container` reattach the managed container to the
    # SAME data; `:verify_integrity` confirms the data is intact before the old
    # container is removed.
    :backup_verify,
    :adopt_credentials,
    :quiesce_old,
    :migrate_volume,
    :resume_old,
    :adopt_volume,
    :adopt_container,
    :verify_integrity
  ]

  @statuses [:pending, :running, :completed, :compensating, :compensated, :failed, :skipped]

  schema "release_steps" do
    field :type, Ecto.Enum, values: @types
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :position, :integer
    field :resource_handle, :map, default: %{}
    field :attempts, :integer, default: 0
    field :error_message, :string

    belongs_to :release, Homelab.Deployments.Release

    timestamps()
  end

  def types, do: @types
  def statuses, do: @statuses

  @required_fields ~w(release_id type position)a
  @optional_fields ~w(status resource_handle attempts error_message)a

  def changeset(step, attrs) do
    step
    |> cast(attrs, @required_fields ++ @optional_fields)
    |> validate_required(@required_fields)
    |> validate_inclusion(:type, @types)
    |> validate_inclusion(:status, @statuses)
    |> foreign_key_constraint(:release_id)
    |> unique_constraint([:release_id, :position])
  end

  @doc """
  Records the outcome of running (or compensating) a step: status plus an
  optional `:handle` (merged into `resource_handle`) and `:error`.
  """
  def progress_changeset(step, status, opts \\ []) do
    attrs = %{status: status}

    attrs =
      if error = Keyword.get(opts, :error), do: Map.put(attrs, :error_message, error), else: attrs

    attrs =
      case Keyword.fetch(opts, :handle) do
        {:ok, handle} -> Map.put(attrs, :resource_handle, handle)
        :error -> attrs
      end

    step
    |> cast(attrs, [:status, :resource_handle, :error_message])
    |> validate_inclusion(:status, @statuses)
  end
end
