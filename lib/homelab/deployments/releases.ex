defmodule Homelab.Deployments.Releases do
  @moduledoc """
  Context for deployment releases: building the ordered plan, guarded state-machine
  transitions (compare-and-set, mirroring `Deployments.transition_status/4`), the
  in-flight lease, and per-deployment generate-once secrets.
  """

  import Ecto.Query

  alias Homelab.Repo
  alias Homelab.Crypto
  alias Homelab.Deployments.{Deployment, Release, ReleaseStep, DeploymentSecret}

  @default_lease_seconds 120

  # --- PubSub ---------------------------------------------------------------

  @doc "Global releases topic — every release transition is broadcast here."
  def topic, do: "releases"

  @doc "Per-deployment releases topic; the deployment detail view subscribes here."
  def topic(deployment_id), do: "releases:deployment:#{deployment_id}"

  defp broadcast_release_updated(deployment_id) do
    msg = {:release_updated, deployment_id}
    Phoenix.PubSub.broadcast(Homelab.PubSub, topic(), msg)
    Phoenix.PubSub.broadcast(Homelab.PubSub, topic(deployment_id), msg)
    :ok
  end

  # --- Planning -------------------------------------------------------------

  @doc """
  Creates a `Release` (status `:planning`) for `deployment` plus its ordered
  steps. `step_specs` is an ordered list of maps, each at least `%{type: t}` and
  optionally `:resource_handle`; positions are assigned 1..n in list order.
  """
  def plan_release(%Deployment{} = deployment, step_specs, opts \\ []) when is_list(step_specs) do
    Repo.transaction(fn ->
      release =
        %Release{}
        |> Release.changeset(%{
          tenant_id: deployment.tenant_id,
          app_template_id: deployment.app_template_id,
          deployment_id: deployment.id,
          plan: Keyword.get(opts, :plan, %{})
        })
        |> Repo.insert()
        |> unwrap()

      step_specs
      |> Enum.with_index(1)
      |> Enum.each(fn {spec, position} ->
        %ReleaseStep{}
        |> ReleaseStep.changeset(Map.merge(%{release_id: release.id, position: position}, spec))
        |> Repo.insert()
        |> unwrap()
      end)

      get_release!(release.id)
    end)
  end

  defp unwrap({:ok, record}), do: record
  defp unwrap({:error, changeset}), do: Repo.rollback(changeset)

  # --- Queries --------------------------------------------------------------

  def get_release!(id), do: Release |> Repo.get!(id) |> Repo.preload(:steps)
  def get_release(id), do: Release |> Repo.get(id) |> preload_steps()

  @doc "The most recent releases for a deployment (newest first), steps preloaded."
  def list_releases_for_deployment(deployment_id, limit \\ 5) do
    Release
    |> where([r], r.deployment_id == ^deployment_id)
    |> order_by([r], desc: r.inserted_at, desc: r.id)
    |> limit(^limit)
    |> Repo.all()
    |> Enum.map(&preload_steps/1)
  end

  @doc "The single active (non-terminal) release for a deployment, if any."
  def get_active_release(deployment_id) do
    Release
    |> where([r], r.deployment_id == ^deployment_id and r.status in ^Release.active_statuses())
    |> Repo.one()
    |> preload_steps()
  end

  @doc "The lowest-position step still `:pending`, or nil."
  def next_pending_step(%Release{} = release) do
    release
    |> ensure_steps()
    |> Map.fetch!(:steps)
    |> Enum.filter(&(&1.status == :pending))
    |> Enum.min_by(& &1.position, fn -> nil end)
  end

  @doc "Completed steps in reverse execution order — the compensation order."
  def completed_steps_desc(%Release{} = release) do
    release
    |> ensure_steps()
    |> Map.fetch!(:steps)
    |> Enum.filter(&(&1.status == :completed))
    |> Enum.sort_by(& &1.position, :desc)
  end

  @doc """
  Deployment ids that currently have a release holding a *live* lease — i.e. a
  legitimately in-flight provisioning. The reconciler skips these so it never
  fights (times out / orphan-sweeps) a deployment a release owns.
  """
  def leased_deployment_ids(now \\ utc_now()) do
    Release
    |> where([r], r.status in ^Release.active_statuses() and r.lease_expires_at > ^now)
    |> select([r], r.deployment_id)
    |> Repo.all()
    |> MapSet.new()
  end

  @doc """
  Active releases whose lease has expired (or was never set) — candidates for the
  reconciler to resume or escalate.
  """
  def list_resumable_releases(now \\ utc_now()) do
    Release
    |> where([r], r.status in ^Release.active_statuses())
    |> where([r], is_nil(r.lease_expires_at) or r.lease_expires_at < ^now)
    |> Repo.all()
    |> Enum.map(&preload_steps/1)
  end

  # --- Guarded transitions --------------------------------------------------

  @doc """
  Compare-and-set the release status. Returns `{:ok, release}` if applied or
  `{:noop, release}` if another writer already advanced it. `opts` may carry
  `:error`, and `:lease_owner`/`:lease_expires_at` (pass `nil` to clear).
  """
  def transition_release(%Release{id: id}, to, from_states, opts \\ [])
      when is_atom(to) and is_list(from_states) do
    set =
      [status: to, updated_at: naive_now()]
      |> put_kw(:error_message, Keyword.get(opts, :error))
      |> put_fetch(:lease_owner, Keyword.fetch(opts, :lease_owner))
      |> put_fetch(:lease_expires_at, Keyword.fetch(opts, :lease_expires_at))

    {count, _} =
      Release
      |> where([r], r.id == ^id and r.status in ^from_states)
      |> Repo.update_all(set: set)

    release = get_release!(id)

    if count == 1 do
      broadcast_release_updated(release.deployment_id)
      {:ok, release}
    else
      {:noop, release}
    end
  end

  @doc """
  Compare-and-set a step status. `opts` may carry `:error` and `:handle` (stored
  in `resource_handle`). Returns `{:ok, step}` or `{:noop, step}`.
  """
  def transition_step(%ReleaseStep{id: id}, to, from_states, opts \\ [])
      when is_atom(to) and is_list(from_states) do
    set =
      [status: to, updated_at: naive_now()]
      |> put_kw(:error_message, Keyword.get(opts, :error))
      |> put_fetch(:resource_handle, Keyword.fetch(opts, :handle))

    {count, _} =
      ReleaseStep
      |> where([s], s.id == ^id and s.status in ^from_states)
      |> Repo.update_all(set: set)

    step = Repo.get!(ReleaseStep, id)

    if count == 1 do
      deployment_id =
        Release
        |> where([r], r.id == ^step.release_id)
        |> select([r], r.deployment_id)
        |> Repo.one()

      broadcast_release_updated(deployment_id)
      {:ok, step}
    else
      {:noop, step}
    end
  end

  # --- Lease ----------------------------------------------------------------

  @doc """
  Atomically acquires/refreshes the lease for `owner` iff it is free (unset or
  expired). Returns `{:ok, release}` or `:taken`.
  """
  def acquire_lease(%Release{id: id}, owner, ttl_seconds \\ @default_lease_seconds) do
    now = utc_now()
    expires = DateTime.add(now, ttl_seconds, :second)

    {count, _} =
      Release
      |> where([r], r.id == ^id)
      |> where([r], is_nil(r.lease_owner) or r.lease_expires_at < ^now or r.lease_owner == ^owner)
      |> Repo.update_all(
        set: [lease_owner: owner, lease_expires_at: expires, updated_at: naive_now()]
      )

    if count == 1, do: {:ok, get_release!(id)}, else: :taken
  end

  def lease_active?(%Release{lease_expires_at: nil}, _now), do: false
  def lease_active?(%Release{lease_expires_at: exp}, now), do: DateTime.compare(exp, now) == :gt

  # --- Secrets --------------------------------------------------------------

  @doc """
  Returns the plaintext secret for `{deployment_id, key}`, generating + persisting
  it (encrypted) on first call. Idempotent: a retry reuses the stored value.
  `generator` is a zero-arity fun returning the plaintext to create.
  """
  def get_or_create_secret(deployment_id, key, generator) when is_function(generator, 0) do
    case Repo.get_by(DeploymentSecret, deployment_id: deployment_id, key: key) do
      %DeploymentSecret{value: value} ->
        Crypto.decrypt(value)

      nil ->
        plaintext = generator.()

        %DeploymentSecret{}
        |> DeploymentSecret.changeset(%{
          deployment_id: deployment_id,
          key: key,
          value: Crypto.encrypt(plaintext)
        })
        |> Repo.insert(on_conflict: :nothing, conflict_target: [:deployment_id, :key])

        # Re-read to resolve the race where a concurrent writer won the insert.
        Repo.get_by!(DeploymentSecret, deployment_id: deployment_id, key: key).value
        |> Crypto.decrypt()
    end
  end

  @doc """
  Upserts an exact secret value for `{deployment_id, key}` (encrypted). Unlike
  `get_or_create_secret/3` this overwrites, so a shared credential can be
  propagated to a companion deployment with the *same* value the app uses.
  """
  def put_secret(deployment_id, key, plaintext) do
    %DeploymentSecret{}
    |> DeploymentSecret.changeset(%{
      deployment_id: deployment_id,
      key: key,
      value: Crypto.encrypt(plaintext)
    })
    |> Repo.insert(
      on_conflict: {:replace, [:value, :updated_at]},
      conflict_target: [:deployment_id, :key]
    )
  end

  @doc "Deletes the given secret keys for a deployment (for adoption-credentials rollback)."
  def delete_secrets(deployment_id, keys) when is_list(keys) do
    {count, _} =
      DeploymentSecret
      |> where([s], s.deployment_id == ^deployment_id and s.key in ^keys)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc "All decrypted secrets for a deployment as a `%{key => plaintext}` map."
  def decrypted_secrets(deployment_id) do
    DeploymentSecret
    |> where([s], s.deployment_id == ^deployment_id)
    |> Repo.all()
    |> Map.new(fn s -> {s.key, Crypto.decrypt(s.value)} end)
  end

  # --- helpers --------------------------------------------------------------

  defp preload_steps(nil), do: nil
  defp preload_steps(%Release{} = r), do: Repo.preload(r, :steps)

  defp ensure_steps(%Release{steps: %Ecto.Association.NotLoaded{}} = r),
    do: Repo.preload(r, :steps)

  defp ensure_steps(%Release{} = r), do: r

  defp put_kw(set, _key, nil), do: set
  defp put_kw(set, key, value), do: Keyword.put(set, key, value)

  defp put_fetch(set, key, {:ok, value}), do: Keyword.put(set, key, value)
  defp put_fetch(set, _key, :error), do: set

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
  defp utc_now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
