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
    # The shared ingress proxy (Traefik). Planned FIRST for a routed release, before
    # any container exists — the proxy is a precondition of the route, not a product
    # of it. Deliberately has no compensation; see `ReleaseSteps.EnsureIngressProxy`.
    :ensure_ingress_proxy,
    :dependency_container,
    :await_health,
    # Applies the credentials the app was configured with to the datastore that has to
    # accept them. Registered in config and fully implemented, but it was NOT in this
    # list — so `Ecto.Enum` would have rejected the row even if a planner emitted one,
    # and none did. A datastore whose volume already holds data ignores
    # MARIADB_USER/PASSWORD entirely (init runs once, on an empty data dir), so the app
    # booted against credentials the database never took and failed from inside itself.
    :ensure_datastore_grants,
    :app_container,
    # A container that joins another deployment's network namespace, and so must be
    # (re)created AFTER the container that owns it — the donor's id is part of the
    # child's create payload. Same handler as the others; the ORDER is the point.
    :netns_child_container,
    # The two halves of "this deployment answers to a name": the local `Domain` row
    # (ownership, exposure, TLS state) and the externally-visible A records. Both run
    # AFTER the app is healthy, because neither should advertise a name that nothing
    # is serving yet. `:publish_dns` compensates; `:sync_domain` compensates only a
    # row it actually created — see the respective handlers.
    :sync_domain,
    :publish_dns,
    :publish_ingress,
    # The last step of a routed release, and the only one that asserts the thing the
    # operator actually wants: that `https://<domain>/` answers, and that the app is what
    # answered. `:publish_ingress` proves the workload is ON the ingress network, which
    # is a precondition of reachability rather than reachability itself — Traefik still
    # has to rebuild its router, ACME still has to issue, DNS still has to propagate, and
    # all three windows sat after the release had already reported success.
    #
    # Advisory in `ReleaseRunner`: it fails loudly and does NOT roll back, because
    # everything it waits on is outside the deploy.
    :verify_public_url,
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
