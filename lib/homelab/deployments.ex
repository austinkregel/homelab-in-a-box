defmodule Homelab.Deployments do
  @moduledoc """
  Context for managing deployments.

  A deployment represents an instance of an app template running
  within a tenant's space.
  """

  import Ecto.Query
  require Logger
  alias Homelab.Repo
  alias Homelab.Deployments.Deployment
  alias Homelab.Deployments.Netns
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Deployments.{Access, Release, ReleaseRunner, Releases}
  alias Homelab.Networking.Hostname
  alias Homelab.Services.ActivityLog

  @doc """
  Executes an adoption/import plan — adopts existing containers in place as
  managed deployments. See `Homelab.Deployments.Adoption.apply_plan/2`.
  """
  defdelegate apply_adoption_plan(plan, opts), to: Homelab.Deployments.Adoption, as: :apply_plan

  @doc """
  Every deployment, ordered the way an operator scans one: what needs attention
  first, then alphabetically.

  This had no `order_by` at all, so callers rendered rows in whatever order the
  database returned them. That is invisible on a full page and wrong on a
  truncated one — the Dashboard shows the first ten, which were an arbitrary ten
  rather than the ten worth looking at.
  """
  def list_deployments do
    Deployment
    |> preload([:tenant, :app_template])
    |> Repo.all()
    |> Enum.sort_by(&{attention_rank(&1.status), template_name(&1)})
  end

  defp attention_rank(:failed), do: 0
  defp attention_rank(:removing), do: 1
  defp attention_rank(:pending), do: 2
  defp attention_rank(:deploying), do: 3
  defp attention_rank(:stopped), do: 4
  defp attention_rank(:running), do: 5
  defp attention_rank(_), do: 6

  defp template_name(%Deployment{app_template: %{name: name}}) when is_binary(name),
    do: String.downcase(name)

  defp template_name(_), do: ""

  def list_deployments_for_tenant(tenant_id) do
    Deployment
    |> where(tenant_id: ^tenant_id)
    |> preload([:app_template])
    |> Repo.all()
  end

  @doc """
  Deployments that are waiting to be deployed and have no container to converge against:
  `:pending`, no `external_id`, untouched since `before`.

  The time bound is the caller's, and it is not optional — every planner creates rows
  and then plans, so a healthy deploy passes through exactly this shape for a moment.
  See `Reconciler.adopt_stranded_pending/1`, which pairs it with "no release has ever
  named this".
  """
  def list_stranded_pending(%DateTime{} = before) do
    Deployment
    |> where([d], d.status == :pending and is_nil(d.external_id))
    |> where([d], d.updated_at < ^DateTime.to_naive(before))
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  def list_desired_states do
    Deployment
    |> where([d], d.status in [:pending, :deploying, :running, :failed])
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  def get_deployment(id) do
    case Repo.get(Deployment, id) |> Repo.preload([:tenant, :app_template]) do
      nil -> {:error, :not_found}
      deployment -> {:ok, deployment}
    end
  end

  def get_deployment!(id) do
    Repo.get!(Deployment, id) |> Repo.preload([:tenant, :app_template])
  end

  @doc """
  The deployments a set of releases actually acts on, keyed by id — each release's anchor
  plus every deployment its steps name through `resource_handle["deployment_id"]`.

  This is what lets a release timeline say WHICH container came up healthy. A step's
  subject is otherwise invisible in the UI: the anchor is the only deployment a release
  row carries, and a stack release runs twenty-odd steps against rows it names only in
  step handles. Rendered without them, a 27-step Media deploy is a column of identical
  "Container healthy" lines.

  Preloads `network_parent`, so a `:netns_child_container` step can name the donor whose
  namespace the child joins — "which network they're in" is the question that step exists
  to answer, and the donor is the answer.

  One query for the whole page. Resolving per step would be twenty-seven.
  """
  def step_subjects(releases) do
    ids =
      releases
      |> List.wrap()
      |> Enum.flat_map(fn release ->
        steps = if is_list(release.steps), do: release.steps, else: []
        [release.deployment_id | Enum.flat_map(steps, &handle_deployment_id/1)]
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()

    by_ids(ids)
  end

  @doc """
  Deployments keyed by id, with the associations a label needs — the template that names
  them and the donor whose namespace they may sit in. Ids that no longer exist are simply
  absent, so a caller rendering history survives a deletion.
  """
  def by_ids(ids) do
    Deployment
    |> where([d], d.id in ^ids)
    |> preload([:app_template, network_parent: :app_template])
    |> Repo.all()
    |> Map.new(&{&1.id, &1})
  end

  # Handles are written by planners (`&1.id`, an integer) and by handlers re-reading their
  # own target, so the value is normally an integer — but `active_release_driving/1`
  # compares the same field as text, and nothing constrains what a handler stores. Both
  # shapes are accepted rather than assumed.
  defp handle_deployment_id(%{resource_handle: %{"deployment_id" => id}}) when is_integer(id),
    do: [id]

  defp handle_deployment_id(%{resource_handle: %{"deployment_id" => id}}) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> [parsed]
      _ -> []
    end
  end

  defp handle_deployment_id(_step), do: []

  @doc """
  Re-reads which deployments live in this one's network namespace, with their templates.

  A fresh read rather than a cached association: the set changes when a SIBLING is
  edited, so a page holding a stale copy would show — and derive a donor's firewall env
  from — a group that no longer matches reality.
  """
  def reload_network_children(%Deployment{} = deployment) do
    Repo.preload(deployment, [network_children: [:app_template, :tenant]], force: true)
  end

  def get_deployment_for_tenant(tenant_id, id) do
    case Deployment
         |> where(tenant_id: ^tenant_id)
         |> where([d], d.id == ^id)
         |> preload([:tenant, :app_template])
         |> Repo.one() do
      nil -> {:error, :not_found}
      deployment -> {:ok, deployment}
    end
  end

  def create_deployment(attrs) do
    %Deployment{}
    |> Deployment.changeset(attrs)
    |> Repo.insert()
    |> case do
      {:ok, deployment} -> {:ok, Repo.preload(deployment, [:tenant, :app_template])}
      error -> error
    end
  end

  def update_deployment(%Deployment{} = deployment, attrs) do
    deployment
    |> Deployment.changeset(attrs)
    |> Repo.update()
    |> case do
      {:ok, updated} ->
        updated = Repo.preload(updated, [:tenant, :app_template], force: true)

        # The Domain row is DERIVED from the deployment, and it used to be written once
        # at first deploy and never revisited — only `do_deploy/1` touched it, and that
        # runs on the create path only. So changing a deployment's domain left the old
        # row (with its TLS state and DNS-zone link) claiming this deployment, and never
        # created one for the new name at all.
        if domain_or_exposure_changed?(deployment, updated), do: sync_domain_records(updated)

        {:ok, updated}

      error ->
        error
    end
  end

  defp domain_or_exposure_changed?(before, mutated) do
    before.domain != mutated.domain or
      before.exposure_mode_override != mutated.exposure_mode_override
  end

  def update_status(%Deployment{} = deployment, status, opts \\ []) do
    deployment
    |> Deployment.status_changeset(status, opts)
    |> Repo.update()
  end

  @doc """
  Atomically transitions a deployment's status, but only if the row is currently
  in one of `from_states`. This is a compare-and-set evaluated in the database, so
  it is race-free against the event stream and the reconciler both writing at once.

  Returns `{:ok, deployment}` if the transition was applied, or `{:noop, deployment}`
  if the guard did not match (some other writer already advanced the row).

  `opts` may carry `:error` (sets `error_message`) and `:external_id`.
  """
  def transition_status(%Deployment{id: id}, to, from_states, opts \\ [])
      when is_atom(to) and is_list(from_states) do
    set =
      [status: to, updated_at: naive_now()]
      |> maybe_set(:error_message, Keyword.get(opts, :error))
      |> maybe_set(:external_id, Keyword.get(opts, :external_id))

    {count, _} =
      Deployment
      |> where([d], d.id == ^id and d.status in ^from_states)
      |> Repo.update_all(set: set)

    deployment = get_deployment!(id)
    if count == 1, do: {:ok, deployment}, else: {:noop, deployment}
  end

  @doc """
  Records `external_id` only if the row does not already have one. Used after a
  guarded status transition no-ops (e.g. the `start`/health event raced ahead of
  the deploy call), so the container id is never lost.
  """
  def ensure_external_id(%Deployment{id: id}, external_id) when is_binary(external_id) do
    Deployment
    |> where([d], d.id == ^id and is_nil(d.external_id))
    |> Repo.update_all(set: [external_id: external_id, updated_at: naive_now()])
  end

  def ensure_external_id(_deployment, _external_id), do: {0, nil}

  @doc """
  Records the id `deploy/1` just returned, overwriting any existing one.

  Distinct from `ensure_external_id/2`, which refuses to clobber. Converging a
  RUNNING deployment no-ops the status transition, and on DockerEngine a converge
  stops, removes and recreates the container — so it hands back a NEW id. Declining
  to write it there would leave `external_id` pointing at a container that no longer
  exists, and every later lookup (logs, stop, reconcile) would chase the corpse.

  The id from `deploy/1` is authoritative: it is the workload we just created.
  """
  def record_external_id(%Deployment{id: id}, external_id) when is_binary(external_id) do
    Deployment
    |> where([d], d.id == ^id)
    |> Repo.update_all(set: [external_id: external_id, updated_at: naive_now()])
  end

  def record_external_id(_deployment, _external_id), do: {0, nil}

  @doc """
  True when a deployment *should* carry a public Traefik route: it's in a reverse-
  proxy access mode AND has a domain. `:host`/`:service` deployments are never
  proxied (a host deployment with a stray domain is not routed). Requires
  `app_template` preloaded.
  """
  def ingress_published?(%Deployment{} = deployment) do
    is_binary(deployment.domain) and deployment.domain != "" and Access.proxy_mode?(deployment)
  end

  @doc """
  Makes a proxy-mode deployment publicly reachable by attaching its workload to the
  shared ingress network. No-op unless it's a proxy mode with a domain, or the
  workload has no container yet.

  This used to connect TRAEFIK to `homelab_<tenant>_<app>_net`, a per-deployment
  network nothing is ever attached to — so it changed nothing and reported success.
  """
  def publish_deployment(%Deployment{external_id: nil}), do: :ok

  def publish_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    # Keyed on the deployment's OWN name — the route a release grants. A donor's ingress
    # membership belongs to its children and is granted by `ensure_ingress_membership/1`.
    if ingress_published?(deployment) do
      ensure_ingress_membership(deployment)
    else
      :ok
    end
  end

  @doc """
  Attaches a workload to the shared ingress network when it must hold an endpoint there:
  a proxy-mode deployment with a domain, or a netns donor carrying a routed child's
  labels. Matches `SpecBuilder`'s `bridge_networks` rule, so a donor with no routed child
  stays single-homed. Idempotent — the driver reads "already exists in network" as
  success.
  """
  def ensure_ingress_membership(%Deployment{external_id: nil}), do: :ok

  def ensure_ingress_membership(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if (ingress_published?(deployment) or carries_child_routes?(deployment)) and
         attachable?(deployment) do
      Homelab.Config.orchestrator().publish(deployment.external_id, ingress_network())
    else
      :ok
    end
  end

  @doc """
  Whether this workload has a network endpoint that CAN be attached to another network.

  A container living in another container's namespace does not: the daemon refuses
  `/networks/<n>/connect` on it with a 403. It is still proxy-mode with a domain — a
  tunneled *arr app behind gluetun is exactly that — but its route is served by its
  DONOR, which SpecBuilder multi-homes onto ingress at create time via
  `bridge_networks`. There is nothing for an attach to do.
  """
  def attachable?(%Deployment{} = deployment) do
    not Netns.child?(deployment) and not Access.host_network_mode?(deployment)
  end

  # The network Traefik resolves backends on — the same one `SpecBuilder` writes into the
  # workload's `traefik.docker.network` label. Passed to the driver rather than assumed
  # by it, so a workload reached over a different network stays expressible.
  defp ingress_network, do: Homelab.Infrastructure.internal_network()

  @doc """
  Severs a deployment's public path by detaching its workload from the shared ingress
  network — Traefik loses the backend address and stops routing to it.

  Detaching something already detached is a no-op, so this also cleans up a stale route
  after an access-mode change.

  NOT safe at a netns donor carrying a routed child's labels: that endpoint is its
  children's only address and is restored only by re-creating the container. Callers on
  a transient path must check `carries_child_routes?/1` first.
  """
  def unpublish_deployment(%Deployment{external_id: nil}), do: :ok

  def unpublish_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    # Same asymmetry as publishing: a workload with no endpoint of its own was never on
    # the ingress network, so there is nothing to detach and the daemon would refuse.
    if attachable?(deployment) do
      Homelab.Config.orchestrator().unpublish(deployment.external_id, ingress_network())
    else
      :ok
    end
  end

  @doc """
  Every deployment whose ingress membership the reconciler's invariant owns (any
  status), preloaded: those holding a domain, plus netns donors of a domain-holding
  child. A gluetun donor holds no domain, so a `domain`-only filter cannot see it.

  `Access.proxy_mode?/1` has no SQL form, so the subquery narrows the rows and
  `carries_child_routes?/1` decides them against the preloaded children.
  """
  def list_ingress_deployments do
    donors_of_named_children =
      from(c in Deployment,
        where: not is_nil(c.network_parent_id) and not is_nil(c.domain) and c.domain != "",
        select: c.network_parent_id
      )

    Deployment
    |> where(
      [d],
      (not is_nil(d.domain) and d.domain != "") or d.id in subquery(donors_of_named_children)
    )
    |> preload([:tenant, :app_template, network_children: :app_template])
    |> Repo.all()
  end

  @doc """
  The deployment routed at `hostname`, or nil.

  Answers the reverse of the routing labels: given a Host header that reached the plane
  because nothing else would take it, which deployment was SUPPOSED to answer? Both
  places a hostname can be stored are searched, because both become Traefik routers —
  `domain`, and every `additional_domains` entry (see
  `SpecBuilder.additional_domain_labels/2`).

  Only deployments that hold a primary `domain` are considered, which is not a
  shortcut: `SpecBuilder.build_routing_labels/2` emits no router at all without one, so
  a row with aliases and no domain was never routed and cannot be what a request was
  looking for.

  The exact-`domain` match is tried alone first. It is what nearly every held request
  is, and it keeps the common case — including a flood of requests to a name that is
  down — off the alias scan.
  """
  @spec get_deployment_by_hostname(String.t() | nil) :: Deployment.t() | nil
  def get_deployment_by_hostname(hostname) do
    case Hostname.normalize(hostname) do
      nil -> nil
      host -> Repo.one(from d in routed_by_domain(host), limit: 1) || by_alias(host)
    end
  end

  defp routed_by_domain(host) do
    from d in Deployment, where: d.domain == ^host, preload: [:tenant, :app_template]
  end

  # `additional_domains` is a JSON column of objects, so there is no index to match a
  # host against. The `LIKE` narrows the rows Postgres hands back to the ones whose JSON
  # so much as mentions the name — a prefilter, not the check: it also matches
  # `not-#{host}` and a host appearing in some other key, so the entry's `"host"` is
  # still compared exactly in Elixir.
  #
  # Gated on `valid?/1`, which is where the LIKE pattern gets its safety: `normalize/1`
  # lowercases and strips a paste apart but does NOT constrain the alphabet, so a Host
  # header carrying `%` or `_` would otherwise reach the pattern as a wildcard. Nothing
  # is lost by refusing it — every stored alias is a validated hostname, so a host that
  # is not one cannot match a row.
  defp by_alias(host) do
    if Hostname.valid?(host), do: scan_aliases(host)
  end

  defp scan_aliases(host) do
    Deployment
    |> where([d], not is_nil(d.domain) and d.domain != "")
    |> where([d], fragment("?::text LIKE ?", d.additional_domains, ^"%#{host}%"))
    |> preload([:tenant, :app_template])
    |> Repo.all()
    |> Enum.find(&aliased?(&1, host))
  end

  defp aliased?(%Deployment{additional_domains: domains}, host) do
    domains
    |> List.wrap()
    |> Enum.any?(fn entry -> is_map(entry) and entry["host"] == host end)
  end

  @doc "Lists ingress-published deployments currently in `:running`, preloaded."
  def list_published_running do
    Deployment
    |> where([d], d.status == :running and not is_nil(d.domain) and d.domain != "")
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  @doc """
  Deployments carrying at least one TCP route, preloaded.

  These are the deployments Traefik has to reach on a TENANT network rather than on
  ingress. A TCP-routed datastore deliberately stays off the ingress network — that
  network is one flat segment shared with every other tenant's routed workload, so
  putting a database on it would open the database to all of them at L3, bypassing
  Traefik entirely. Traefik joins the tenant network instead, which grants reach to the
  one process that already reaches every routed workload and grants the datastore
  nothing. `Infrastructure.sync_traefik_networks/0` is what acts on this.
  """
  def list_tcp_routed do
    Deployment
    |> where([d], fragment("cardinality(?) > 0", d.tcp_routes))
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  @doc "All non-nil external_ids across every deployment, for orphan detection."
  def list_all_external_ids do
    Deployment
    |> where([d], not is_nil(d.external_id))
    |> select([d], d.external_id)
    |> Repo.all()
  end

  @doc "All deployment ids, for the reconciler's adoption-protection check."
  def list_all_ids do
    Deployment
    |> select([d], d.id)
    |> Repo.all()
  end

  defp maybe_set(set, _key, nil), do: set
  defp maybe_set(set, key, value), do: Keyword.put(set, key, value)

  defp naive_now, do: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

  def mark_for_removal(%Deployment{} = deployment) do
    update_status(deployment, :removing)
  end

  def mark_reconciled(%Deployment{} = deployment) do
    deployment
    |> Deployment.reconciled_changeset()
    |> Repo.update()
  end

  def mark_unhealthy(external_id) do
    Deployment
    |> where(external_id: ^external_id)
    |> Repo.update_all(set: [status: :failed])
  end

  @doc """
  Deletes a deployment row.

  Refused while anything is living in its network namespace. A child cannot survive
  losing its donor — its `NetworkMode` names a container id that would no longer exist,
  so the daemon refuses to start it — and the alternative to refusing is worse than a
  broken child: silently reattaching a tunneled app to the tenant network puts its
  traffic OUTSIDE the VPN, which for the apps people put behind gluetun is the one
  outcome the whole arrangement exists to prevent. The database enforces this too
  (`on_delete: :restrict`); this is the version that can explain itself.
  """
  def delete_deployment(%Deployment{} = deployment) do
    case Netns.children(Repo.preload(deployment, :network_children)) do
      [] ->
        Repo.delete(deployment)

      children ->
        {:error, {:netns_donor_in_use, Enum.map(children, & &1.id)}}
    end
  end

  @spec stop_deployment(Deployment.t()) :: {:ok, Deployment.t()} | {:error, Ecto.Changeset.t()}
  def stop_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if deployment.external_id do
      _ = Homelab.Config.orchestrator().undeploy(deployment.external_id)
    end

    update_deployment(deployment, %{status: :stopped, external_id: nil})
  end

  @spec start_deployment(Deployment.t()) :: {:ok, Deployment.t()} | {:error, term()}
  def start_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])
    orchestrator = Homelab.Config.orchestrator()

    case SpecBuilder.build(deployment) do
      {:ok, spec} ->
        case orchestrator.deploy(spec) do
          {:ok, external_id} ->
            case transition_status(
                   deployment,
                   :deploying,
                   [:pending, :deploying, :stopped, :failed],
                   external_id: external_id
                 ) do
              {:ok, _} ->
                :ok

              # Already :running — this was a converge, not a cold start. The workload
              # never stopped, so the status is right as it is; only the id may have
              # moved (DockerEngine recreates the container on converge).
              {:noop, _} ->
                record_external_id(deployment, external_id)
            end

            {:ok, get_deployment!(deployment.id)}

          {:error, reason} ->
            update_status(deployment, :failed, error: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        update_status(deployment, :failed, error: inspect(reason))
        {:error, reason}
    end
  end

  @spec restart_deployment(Deployment.t()) ::
          {:ok, Deployment.t()} | {:error, :not_deployed | :restart_failed}
  def restart_deployment(%Deployment{external_id: nil}), do: {:error, :not_deployed}

  def restart_deployment(%Deployment{} = deployment) do
    case Homelab.Config.orchestrator().restart(deployment.external_id) do
      :ok ->
        update_status(deployment, :deploying)

      {:error, _reason} ->
        {:error, :restart_failed}
    end
  end

  @doc """
  Removes a deployment's container and then its DB row. The row is deleted *only*
  if the container removal succeeds, so a failed undeploy can never strand a
  labeled container with no deployment record (which the orphan sweep would then
  reap). On failure the row is kept and marked `:failed` with the error, so the
  user sees it and can retry the delete once Docker is reachable.

  Refused outright while anything lives in this deployment's network namespace — see
  `delete_deployment/1` for why detaching the children silently is the worse option.
  """
  def destroy_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template, :network_children])

    case Netns.children(deployment) do
      [] ->
        do_destroy(deployment)

      children ->
        {:error, {:netns_donor_in_use, Enum.map(children, & &1.id)}}
    end
  end

  defp do_destroy(deployment) do
    case undeploy_container(deployment) do
      :ok ->
        Repo.delete(deployment)

      {:error, reason} ->
        _ = update_status(deployment, :failed, error: "Undeploy failed: #{inspect(reason)}")
        {:error, {:undeploy_failed, reason}}
    end
  end

  defp undeploy_container(%Deployment{external_id: nil}), do: :ok

  defp undeploy_container(%Deployment{external_id: external_id}),
    do: Homelab.Config.orchestrator().undeploy(external_id)

  @doc """
  Applies a deployment's current config to its running workload IMPERATIVELY, in the
  caller's process. The new spec is rebuilt from the row by `SpecBuilder.build/1`, so
  pass the deployment after persisting any changes.

  Not the path a config save takes — that is `reconverge_release/1`, which does the same
  thing through the saga and so leaves a `Release` behind to look at. This one is for
  callers that must know the deploy succeeded before they return, and `Reclaim.reclaim/1`
  is the reason it still exists: it has just removed a Swarm service and cannot report
  `{:redeploy_failed, reason}` about work that has not happened yet.

  This CONVERGES rather than undeploying first, and the difference is downtime.

  `deploy/1` on both orchestrators pulls the image FIRST and then creates-or-
  converges: Swarm rolls the new spec onto the existing service in place, and
  DockerEngine replaces the container on a name conflict. Undeploying first threw
  that away — the service was removed, and only THEN did the pull start, so the app
  stayed down for the entire image download rather than for a container restart.
  On a fat image that is minutes instead of seconds, and it happened on every
  config save (editing one env var blacked the app out for a download).

  Safe when stopped/failed: there is simply no existing workload to converge onto.
  """
  def recreate_deployment(%Deployment{} = deployment) do
    start_deployment(deployment)
  end

  def change_deployment(%Deployment{} = deployment, attrs \\ %{}) do
    Deployment.changeset(deployment, attrs)
  end

  @doc """
  Creates a deployment record and immediately deploys the container.
  Returns `{:ok, deployment}` on success or `{:error, reason}` on failure.
  The Docker event listener will transition status to `:running` once the
  container starts.
  """
  def deploy_now(attrs) do
    with {:ok, deployment} <- create_deployment(attrs) do
      do_deploy(deployment)
    end
  end

  @doc """
  Creates a deployment and provisions it through the durable release saga —
  the replacement for `deploy_now/1`, which deploys imperatively inside the caller's
  request with no release row, no health gate, no ingress-after-healthy and no
  rollback.

  Returns `{:ok, %{deployment: deployment, release: release}}`. Callers need both: the
  deployment to redirect to, the release to show progress against.

  ## The pre-flight is the point

  `SpecBuilder.build/1` is run synchronously against the app and every companion
  BEFORE anything is created or planned. Without it the saga swallows the single most
  common deploy error: `deploy_now/1` returns `{:error, {:missing_required_env, [...]}}`
  in-request and the wizard flashes it, whereas an unchecked saga would create the row,
  enqueue the job, hand the operator a green "deployment started", and then roll the
  whole thing back seconds later in the background. A silently-reverted success is
  worse than a loud failure.

  It costs nothing: `SpecBuilder.build/1` is a pure read over rows already loaded, and
  `DeployContainer` rebuilds the spec anyway.

  ## Why the enqueue is outside the transaction

  Create-and-plan is one `Repo.transaction`, so a failed plan cannot leave a deployment
  row with no release. The Oban insert cannot join it: Oban runs on `Homelab.ObanRepo`,
  a physically separate Postgres, so there is no transaction spanning both.

  That is a property, not a wart. Enqueuing inside would be a lie (the job would be
  visible to a worker before the release row committed); enqueuing after means the only
  failure window leaves a committed `:planning` release with no job — and
  `Reconciler.resume_stuck_releases/0` re-enqueues exactly those on its next tick. The
  system converges; it does not lose the deploy.
  """
  def create_and_deploy_release(attrs, companions \\ []) when is_list(companions) do
    Repo.transaction(fn ->
      with {:ok, deployment} <- create_deployment(attrs),
           deployment = get_deployment!(deployment.id),
           # The same set `plan_deploy_release/3` will plan, built by the same function, so
           # the pre-flight cannot check a different set from the one that gets deployed.
           # It is passed twice over: once as the things to BUILD (with the app), and once
           # as the donors this release will bring up, which is what lets the netns
           # liveness check be skipped for exactly those.
           all_companions = companion_set(deployment, companions),
           :ok <- preflight_specs([deployment | all_companions], all_companions),
           {:ok, release} <- plan_deploy_release(deployment, companions, []) do
        %{deployment: deployment, release: release}
      else
        {:error, reason} -> Repo.rollback(reason)
        other -> Repo.rollback(other)
      end
    end)
    |> case do
      {:ok, %{release: release} = result} ->
        ReleaseRunner.enqueue_or_log(release)
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Fails on the FIRST unbuildable spec and returns that reason verbatim, so callers
  # keep matching on `{:error, {:missing_required_env, keys}}` exactly as they do
  # against `deploy_now/1`.
  #
  # With ONE exception, and it is narrow on purpose. `SpecBuilder.resolve_netns_donor/1`
  # fails closed on a donor that has no container yet — correctly, because a create
  # naming an absent container produces one the daemon will never start. But a donor
  # THIS release is about to deploy has exactly that shape at plan time, and the release
  # is what establishes the precondition: the donor is planned first and awaited healthy
  # before the child's container is created. SpecBuilder's own comment says as much.
  # Asserting it here made `create_and_deploy_release/2` unable to create a netns child
  # at all — the transaction rolled back and no deployment was written.
  #
  # Scoped to donors in this release's companion set, not to netns errors in general: a
  # donor that is genuinely missing, or one nothing is going to deploy, still fails fast.
  # And it costs no other coverage — `SpecBuilder.build/1` validates required env BEFORE
  # it resolves the donor, so everything the pre-flight exists for has already run by
  # the time this error can be returned.
  defp preflight_specs(deployments, companions) do
    deployable = MapSet.new(companions, & &1.id)

    Enum.reduce_while(deployments, :ok, fn deployment, :ok ->
      case SpecBuilder.build(with_associations(deployment)) do
        {:ok, _spec} ->
          {:cont, :ok}

        {:error, {:netns_donor_not_running, donor_id}} = error ->
          if MapSet.member?(deployable, donor_id), do: {:cont, :ok}, else: {:halt, error}

        {:error, _reason} = error ->
          {:halt, error}
      end
    end)
  end

  @doc """
  The deployment with the associations every access-mode predicate reads.

  A no-op for rows the caller already loaded — which is all of them on the common path,
  where re-fetching by id would query the same deployment three times.
  """
  def with_associations(%Deployment{} = deployment),
    do: Repo.preload(deployment, [:tenant, :app_template])

  @doc """
  Provisions a deployment (and any companion deployments) durably via the release
  saga instead of the imperative in-request path: plans the ordered steps and
  enqueues `ReleaseRunner`. Companions are deployed and awaited healthy before the
  app, the app is awaited, then the name and reachability steps run — each of which
  skips itself at runtime when the deployment holds no name to publish.

  Both `app` and each companion must already exist as `:pending` deployment rows
  (their `env_overrides` carry any shared credentials). Returns `{:ok, release}`.

  This is the path that fixes multi-stage deploys: a release can only reach
  `:running` once its `:app_container` step has run, and a failure rolls back the
  companions so nothing is orphaned.
  """
  def deploy_release(%Deployment{} = app, companions \\ [], opts \\ [])
      when is_list(companions) do
    with {:ok, release} <- plan_deploy_release(app, companions, opts) do
      ReleaseRunner.enqueue_or_log(release)
      {:ok, release}
    end
  end

  # The plan, without the enqueue. Split out so `create_and_deploy_release/2` can put
  # the whole create-and-plan inside one transaction and enqueue only after it commits
  # (Oban lives on a different repo — see that function).
  defp plan_deploy_release(%Deployment{} = app, companions, _opts) do
    all_companions = companion_set(app, companions)

    steps =
      prepare_steps() ++
        Enum.flat_map(all_companions, &dependency_steps(app, &1)) ++
        workload_steps() ++
        ingress_steps()

    with :ok <- ensure_none_in_flight([app | all_companions]) do
      Releases.plan_release(app, steps)
    end
  end

  # Refuses to plan while ANY deployment this release would drive is already being
  # driven by another one.
  #
  # `releases_one_active_per_deployment` covers `releases.deployment_id` and stops there,
  # so it never sees a companion — those are named by a step's
  # `resource_handle["deployment_id"]`. Nothing else checked, and the gap is not exotic:
  # "deploy the VPN donor, then deploy an app behind it before the donor's release has
  # finished" is the ordinary flow, and `netns_donor_companions/1` resolves that donor
  # into the second release's set automatically. Both sagas would then call
  # `orchestrator.deploy` for it, both would write its `external_id`, and a rollback of
  # either would undeploy the container the other had just created.
  #
  # The app is checked with the same query rather than leaning on the index: the index
  # cannot see the case where the in-flight release names it as a COMPANION.
  #
  # A typed error, never a raise — `Adoption.adopt/2` has used exactly this guard, in
  # exactly this shape, since before the saga had a second entry point.
  defp ensure_none_in_flight(deployments) do
    Enum.reduce_while(deployments, :ok, fn deployment, :ok ->
      case Releases.active_release_driving(deployment.id) do
        nil -> {:cont, :ok}
        _release -> {:halt, {:error, {:release_in_flight, deployment.id}}}
      end
    end)
  end

  # Every deployment that must be up before the app: its netns donor, plus whatever the
  # caller named. De-duplicated BY ID, and this is the only place that can be — the donor
  # and the caller's list are only visible together here.
  #
  # The dedup is load-bearing, not defensive. A compose bundle where gluetun is both the
  # namespace donor and an explicit companion (`deploy_release/2` from the wizard's
  # compose path) otherwise yields two `:dependency_container` steps for one deployment.
  # Both write `external_id`, so only the second is compensatable and the first container
  # is orphaned — or the second collides on `service_name/2` and fails a release that
  # should have succeeded.
  #
  # This lived as a comment on `netns_donor_companions/1` claiming the set WAS
  # de-duplicated while nothing on the path did it. Enforcing it here means every caller
  # gets it, rather than each one having to remember not to pass the donor through.
  defp companion_set(%Deployment{} = app, companions) do
    (netns_donor_companions(app) ++ companions)
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Does this deployment answer to a name of its OWN? Distinct from `routed?/1`, and
  the distinction is the netns donor: a name is a property of the deployment that
  holds it, while reachability is a property of the container Traefik can resolve,
  and for a tunneled stack those are two different deployments.
  """
  def own_domain?(%Deployment{domain: domain}), do: is_binary(domain) and domain != ""

  @doc """
  Does traffic from the proxy reach this deployment? The ONE definition of "routed",
  read by `ReleaseFacts` and by anything else that has to agree with it.

  A donor with routed children is routed even with no domain of its own — the ordinary
  gluetun shape, where every name in the stack belongs to a child. `SpecBuilder` emits
  `traefik.enable` and multi-homes such a donor onto the ingress network, because a
  child has no endpoint for Traefik to discover and its route resolves to the DONOR's
  address.
  """
  def routed?(%Deployment{} = deployment) do
    own_domain?(deployment) or carries_child_routes?(deployment)
  end

  @doc """
  True when a routed child's public path runs through this deployment's container, so
  the donor holds an ingress endpoint that is not its own route. See
  `Homelab.Deployments.Netns`. Reads preloaded `:network_children` when present.
  """
  def carries_child_routes?(%Deployment{} = deployment),
    do: Enum.any?(Netns.children(deployment), &routes_via_donor?/1)

  # `Access.proxy_mode?/1` reads the template, and a caller's preloaded
  # `:network_children` is not guaranteed to carry one — `Repo.preload/2` on an
  # already-loaded association is a no-op, so this is only a cost when it is needed.
  # Short-circuits on `own_domain?/1`, which is a plain field read.
  defp routes_via_donor?(%Deployment{} = child),
    do: own_domain?(child) and Access.proxy_mode?(Repo.preload(child, :app_template))

  # Every planner emits the same stages; each handler's `skip?/2` decides at runtime
  # whether its step acts.

  # The proxy has to exist before anything that routes through it, and the credentials
  # before the containers that consume them. Public for `Adoption`, the third planner.
  @doc false
  def prepare_steps do
    [
      %{stage: :prepare, type: :ensure_ingress_proxy, resource_handle: %{}},
      %{stage: :prepare, type: :provision_credentials, resource_handle: %{}}
    ]
  end

  # One companion: bring it up, wait for it, then reconcile the app's credentials
  # against it.
  defp dependency_steps(%Deployment{} = app, %Deployment{} = companion) do
    [
      %{
        stage: :dependencies,
        type: :dependency_container,
        resource_handle: %{"deployment_id" => companion.id}
      },
      %{
        stage: :dependencies,
        type: :await_health,
        resource_handle: %{"deployment_id" => companion.id}
      },
      # Before the app starts, so it never boots against a database that is not there.
      %{
        stage: :dependencies,
        type: :ensure_databases,
        resource_handle: %{"deployment_id" => companion.id}
      }
    ] ++ datastore_grant_steps(app, companion)
  end

  # The release's own workload. The database step covers a datastore deployed on its
  # own — the companion case is handled in `dependency_steps/2` — and skips itself for
  # every deployment that is not one.
  defp workload_steps do
    [
      %{stage: :workload, type: :app_container, resource_handle: %{}},
      %{stage: :workload, type: :await_health, resource_handle: %{}},
      %{stage: :workload, type: :ensure_databases, resource_handle: %{}}
    ]
  end

  # One container living in the donor's namespace, created after the donor exists
  # because the donor's container id is part of the child's create payload.
  defp namespace_steps(%Deployment{} = child) do
    [
      %{
        stage: :namespace,
        type: :netns_child_container,
        resource_handle: %{"deployment_id" => child.id}
      },
      %{
        stage: :namespace,
        type: :await_health,
        resource_handle: %{"deployment_id" => child.id}
      }
    ]
  end

  # Claiming a NAME: the local `Domain` row and the A records that resolve it. `handle`
  # targets them; an empty handle means the release's own deployment.
  defp name_steps(handle \\ %{}) do
    [
      %{stage: :naming, type: :sync_domain, resource_handle: handle},
      %{stage: :naming, type: :publish_dns, resource_handle: handle}
    ]
  end

  # Granting REACHABILITY: attaching the workload to the shared ingress network so
  # Traefik can resolve it. The condition is `PublishIngress.skip?/2`.
  defp reachability_steps do
    [%{stage: :reachability, type: :publish_ingress, resource_handle: %{}}]
  end

  # The tail of a routed release, all of it after the app is healthy: claim the name
  # locally, publish it to DNS, grant reachability, then CHECK it.
  #
  # Ordered so nothing advertises a name before something answers to it, and so
  # compensation (which walks descending) severs reachability first, then DNS, then the
  # row. The verification is last because it is the only step that observes the result of
  # all three rather than performing one of them.
  #
  # Public (but undocumented) for `Adoption`, the third planner.
  @doc false
  def ingress_steps do
    name_steps() ++ reachability_steps() ++ verify_steps()
  end

  # Does the URL answer? `handle` targets one deployment, so each netns child checks the
  # name it holds rather than the donor that serves it.
  defp verify_steps(handle \\ %{}) do
    [%{stage: :verification, type: :verify_public_url, resource_handle: handle}]
  end

  # Reconciles the app's credentials against a datastore companion, AFTER that companion
  # is healthy and BEFORE the app starts. See `Datastore.Grants`.
  defp datastore_grant_steps(%Deployment{} = app, %Deployment{} = companion) do
    [
      %{
        stage: :dependencies,
        type: :ensure_datastore_grants,
        resource_handle: %{
          "deployment_id" => companion.id,
          "app_deployment_id" => app.id
        }
      }
    ]
  end

  # A netns child's donor is a dependency in the strictest sense: the child's create
  # payload contains the donor's CONTAINER ID, so the donor must exist and be running
  # first. The saga already expresses exactly this — companions are deployed and awaited
  # healthy before the app — so the donor is prepended to the companion list rather than
  # needing an ordering mechanism of its own.
  #
  # NOT de-duplicated on its own — `companion_set/2` owns that, because dedup can only
  # happen where the donor and the caller's companions are combined.
  defp netns_donor_companions(%Deployment{network_parent_id: nil}), do: []

  defp netns_donor_companions(%Deployment{} = app) do
    case Netns.donor(app) do
      nil -> []
      donor -> [donor]
    end
  end

  @doc """
  Re-drives a whole network-namespace stack: the donor first, then every container
  living in its namespace.

  This is the cascade sharing a namespace costs. Re-creating the donor mints a NEW
  container id, and each child's `NetworkMode` still names the old one — Docker will not
  start such a container at all ("cannot join network of a non running container"), so
  the children are not merely stale, they are dead until re-created against the new id.

  So: any change that re-creates the donor — including a change to a CHILD's route,
  since a child's Traefik labels live on the donor — has to re-create the children too.
  Callers pass any member of the stack; the donor is resolved from it.

  A plain config change on a child (env, volumes) does not go through here: it does not
  touch the donor, so `reconverge_release/1` is both sufficient and much cheaper.

  `opts[:plan]` is stored on the release verbatim. Callers use it to say WHY the stack
  is going round — the Releases tab renders `plan["kind"]` as a badge — because the step
  list cannot tell a config save apart from the reconciler re-creating a stale child.
  """
  def redeploy_netns_stack(%Deployment{} = deployment, opts \\ []) do
    donor =
      case Netns.donor(deployment) do
        nil -> deployment
        parent -> parent
      end

    # Children carry their templates: `carries_child_routes?/1` reads each child's
    # effective exposure, and a shallow preload would make that one query per child.
    donor =
      Repo.preload(donor, [:tenant, :app_template, network_children: [:app_template, :tenant]])

    children = Netns.children(donor)

    # Each child's OWN name and URL: the donor carries its Traefik labels, but the name
    # being served belongs to the child.
    child_name_steps =
      Enum.flat_map(children, &name_steps(%{"deployment_id" => &1.id}))

    child_verify_steps =
      Enum.flat_map(children, &verify_steps(%{"deployment_id" => &1.id}))

    # Ingress LAST, after the children exist.
    #
    # The donor's Traefik labels serve the CHILDREN's routes — that is the whole reason
    # a child's route change re-creates the donor. Publishing before the children were
    # (re)created advertised every one of those routes to a namespace holding nothing
    # yet, so the window between "donor healthy" and "last child healthy" served 502s on
    # names that had been working a moment earlier. The proxy still goes first: it is a
    # precondition, not an advertisement.
    steps =
      prepare_steps() ++
        workload_steps() ++
        Enum.flat_map(children, &namespace_steps/1) ++
        name_steps() ++
        child_name_steps ++
        reachability_steps() ++
        verify_steps() ++ child_verify_steps

    # Settled first, for the reason on `reconverge_release/1`: the newest plan wins, and a
    # refusal must not have reset the donor and its children on the way to being refused.
    #
    # There was no guard here at all before — a second save while the stack was still
    # going round collided on `releases_one_active_per_deployment` inside `plan_release/3`,
    # which surfaced to the operator as a raw constraint error on a form that had already
    # saved their edit.
    with :ok <- supersede_or_refuse(donor.id),
         {:ok, donor} <- reset_to_pending(donor),
         {:ok, _children} <- reset_all_to_pending(children),
         {:ok, release} <- Releases.plan_release(donor, steps, Keyword.take(opts, [:plan])) do
      ReleaseRunner.enqueue_or_log(release)
      {:ok, release}
    end
  end

  @doc """
  Re-drives the stack that governs `deployment` by planning a FRESH release and
  enqueuing it. Works from any member of the stack — the app or one of its
  companions: it resolves the driving release, rebuilds the app + companion set
  from that release's steps, resets them to `:pending`, and re-runs
  `deploy_release/2`.

  Refuses with `{:error, :release_active}` while a release is still in flight —
  the one-active-per-deployment constraint would reject a new plan, and
  re-driving a live release would race the running saga. When there is no prior
  release, deploys the single deployment standalone.

  A member of a network-namespace group goes round as a GROUP, through
  `redeploy_netns_stack/1`. Re-creating any member mints a container id the others are
  pinned to, so re-running a donor alone leaves its children naming a container that no
  longer exists, and re-running a child alone does the same to its siblings.
  """
  def redeploy(%Deployment{} = deployment) do
    release = Releases.driving_release(deployment.id)

    cond do
      release && not Release.terminal?(release) -> {:error, :release_active}
      netns_member?(deployment) -> redeploy_netns_stack(deployment)
      is_nil(release) -> deploy_standalone(deployment)
      true -> replay(release)
    end
  end

  defp netns_member?(%Deployment{} = deployment),
    do: Netns.child?(deployment) or Netns.donor?(deployment)

  defp deploy_standalone(deployment) do
    with {:ok, app} <- reset_to_pending(deployment) do
      deploy_release(app)
    end
  end

  # The same app and companion set the prior release drove, reset and planned afresh.
  defp replay(%Release{} = release) do
    app = get_deployment!(release.deployment_id)

    companions =
      release.steps
      |> Enum.filter(&(&1.type == :dependency_container))
      |> Enum.map(&get_in(&1.resource_handle, ["deployment_id"]))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.map(&get_deployment!/1)

    with {:ok, app} <- reset_to_pending(app),
         {:ok, companions} <- reset_all_to_pending(companions) do
      deploy_release(app, companions)
    end
  end

  @doc """
  Re-drives ONE deployment through the release saga after its configuration changed:
  plans the lifecycle backbone with no companions against the row as it now stands,
  resets it to `:pending`, and enqueues `ReleaseRunner`.

  This is what a config save runs. It replaces `recreate_deployment/1` on that path,
  which called `start_deployment/1` synchronously inside the LiveView process — the
  container was replaced correctly, but with none of the saga around it: no health gate,
  no ingress-after-healthy, no rollback, no in-flight guard, and no `Release` row, so a
  version bump or a network edit left the Releases tab showing nothing at all. The edits
  that reach here are not small (image, network mode, published ports, routed port,
  domain and its Traefik labels), and the imperative path applied every one of them with
  no way to see what happened or to undo it.

  ## Why the companions are left alone

  Deliberately NOT `redeploy/1`, which resolves the driving release, pulls the companion
  set out of its `:dependency_container` steps and resets those rows too. That is right
  for "re-run this deploy from the start" — it is what the button means — and wrong for
  a config save: bumping an app's image tag would recreate the Postgres behind it,
  minting a new container id and taking the datastore down for a change that never
  touched it.

  So the step list is `plan_deploy_release/3`'s with the companion block omitted. The
  ingress steps ARE included: a config save is the operation most likely to move a
  route, and the labels that serve it live on the container this release replaces.

  A companion that must come along is not silently skipped — it is refused. A netns
  child's donor, or anything else the saga would have to bring up first, is caught by
  `ensure_none_in_flight/1` if it is mid-release, and by `SpecBuilder.build/1` at
  `DeployContainer` if it is absent. Neither is a case this function can quietly get
  wrong; both surface as a failed step with the reason on it.

  Callers holding a netns group take `redeploy_netns_stack/1` instead — a member cannot
  converge alone, because re-creating it mints a container id the others are pinned to.

  Returns `{:ok, release}`, or `{:error, {:release_in_flight, id}}` when something is
  already driving this deployment. The refusal matters on this path specifically: the
  caller has ALREADY persisted the new config by the time it gets here, so the row and
  the running container disagree until a release applies it. Callers say exactly that
  rather than reporting a failed save.
  """
  def reconverge_release(%Deployment{} = deployment) do
    deployment = with_associations(deployment)

    steps = prepare_steps() ++ workload_steps() ++ ingress_steps()

    # Settled BEFORE the reset, so a refused save leaves the row exactly as the caller
    # persisted it. Resetting first would clear `external_id` on a deployment another
    # release is actively driving — the one thing that release needs to compensate.
    with :ok <- supersede_or_refuse(deployment.id),
         {:ok, deployment} <- reset_to_pending(deployment),
         {:ok, release} <-
           Releases.plan_release(deployment, steps, plan: %{"kind" => "reconfigure"}) do
      ReleaseRunner.enqueue_or_log(release)
      {:ok, release}
    end
  end

  # Clears the way for a release anchored on `anchor_id`: the newest plan wins, so an
  # in-flight release for the same anchor is handed over rather than blocking the save.
  #
  # This replaced a flat refusal, which made the LAST save the one that lost — you
  # changed the image, changed your mind about the port before the first release had
  # finished, and the port edit was persisted but never applied. Nothing said so
  # afterwards either: the row and the running container simply disagreed until someone
  # pressed the button again.
  #
  # Two cases still refuse, and neither is a config save racing itself:
  #
  #   * A release anchored on a DIFFERENT deployment that names this one as a companion
  #     — the "app + its datastore" shape. Superseding it would abandon the app's deploy
  #     halfway through because somebody edited the datastore's env, and the new release
  #     covers only the datastore, so nothing would ever finish the app. The narrower
  #     operation must not cancel the wider one.
  #
  #   * An ADOPTION. Its steps move data (`migrate_copy`, `verify_integrity`,
  #     `backup_verify`), and standing one down mid-walk leaves a copy half-made that a
  #     fresh container would then be pointed at. `abandon_release/2` makes the same
  #     argument about not acting on a plan you have stopped believing.
  #
  # `:rolling_back` needs no case of its own: `supersede_release/1` only transitions from
  # `:planning` or `:provisioning`, so a rollback in progress falls out as a `{:noop, _}`
  # that is still active, and is refused below.
  defp supersede_or_refuse(anchor_id) do
    case Releases.active_release_driving(anchor_id) do
      nil -> :ok
      release -> hand_over(release, anchor_id)
    end
  end

  # Same anchor: this plan replaces that one, so hand the deployment over.
  defp hand_over(%{deployment_id: anchor_id} = release, anchor_id) do
    if adoption?(release) do
      {:error, {:release_in_flight, anchor_id}}
    else
      case Releases.supersede_release(release) do
        {:ok, _superseded} ->
          :ok

        # It settled on its own between the read and the write. Terminal means the way is
        # clear anyway; still-active means it moved to `:rolling_back`, which has to be
        # left alone to finish undoing itself.
        {:noop, %{status: status}} ->
          if status in Release.active_statuses(),
            do: {:error, {:release_in_flight, anchor_id}},
            else: :ok
      end
    end
  end

  # A different anchor — this deployment is a COMPANION in somebody else's release.
  defp hand_over(_other, anchor_id), do: {:error, {:release_in_flight, anchor_id}}

  defp adoption?(%{plan: plan}) when is_map(plan), do: Map.get(plan, "kind") == "adoption"
  defp adoption?(_release), do: false

  # Resets a deployment to `:pending` and clears the stale container id so the
  # re-driven release provisions it fresh; returns a fully-preloaded struct.
  defp reset_to_pending(%Deployment{} = deployment) do
    with {:ok, _} <- update_deployment(deployment, %{status: :pending, external_id: nil}) do
      {:ok, get_deployment!(deployment.id)}
    end
  end

  defp reset_all_to_pending(deployments) do
    Enum.reduce_while(deployments, {:ok, []}, fn deployment, {:ok, acc} ->
      case reset_to_pending(deployment) do
        {:ok, reset} -> {:cont, {:ok, [reset | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, reset} -> {:ok, Enum.reverse(reset)}
      error -> error
    end
  end

  defp do_deploy(deployment) do
    ensure_traefik_if_needed(deployment)

    case SpecBuilder.build(deployment) do
      {:ok, spec} ->
        case Homelab.Config.orchestrator().deploy(spec) do
          {:ok, external_id} ->
            ActivityLog.info("deploy", "#{deployment.app_template.name} deployed", %{
              deployment_id: deployment.id,
              external_id: external_id
            })

            # Guarded: never clobber a :running/:failed the event stream may have
            # already written while deploy/1 was in flight. If it no-ops, still
            # persist the container id so reconciliation can match it later.
            case transition_status(deployment, :deploying, [:pending, :deploying],
                   external_id: external_id
                 ) do
              {:ok, _} -> :ok
              {:noop, _} -> ensure_external_id(deployment, external_id)
            end

            post_deploy_hooks(deployment)
            {:ok, get_deployment!(deployment.id)}

          {:error, reason} ->
            ActivityLog.error(
              "deploy",
              "#{deployment.app_template.name} failed: #{inspect(reason)}",
              %{deployment_id: deployment.id}
            )

            update_status(deployment, :failed, error: inspect(reason))
            {:error, reason}
        end

      {:error, reason} ->
        ActivityLog.error(
          "deploy",
          "#{deployment.app_template.name} spec build failed: #{inspect(reason)}",
          %{deployment_id: deployment.id}
        )

        update_status(deployment, :failed, error: inspect(reason))
        {:error, reason}
    end
  end

  defp ensure_traefik_if_needed(%{domain: domain}) when is_binary(domain) and domain != "" do
    case ensure_proxy() do
      {:ok, :already_running} ->
        :ok

      {:ok, :started} ->
        ActivityLog.info("infrastructure", "Traefik started")

      # A catch-all, NOT just `{:error, reason}`. `ensure_traefik/0` is a `with` with no
      # `else`, so it returns whatever any clause returned — including
      # `Docker.Network.ensure/1`'s shapes. Matching only the three expected returns
      # raises `CaseClauseError`, and this call sits outside the saga runner's rescue:
      # it would propagate out of `do_deploy/1` to the controller or LiveView, failing
      # the whole deploy over a best-effort ingress step. `ensure_ingress_proxy.ex`
      # makes the same argument for the saga path.
      other ->
        ActivityLog.error("infrastructure", "Traefik failed: #{inspect(other)}")
    end
  end

  defp ensure_traefik_if_needed(_deployment), do: :ok

  # The same seam, under the same key, as the saga's `EnsureIngressProxy` step: both
  # call sites are the same question asked of the same function, and a test that drives
  # one has to be able to drive the other.
  defp ensure_proxy do
    case Application.get_env(:homelab, :ingress_proxy_ensurer) do
      fun when is_function(fun, 0) -> fun.()
      _ -> Homelab.Infrastructure.ensure_traefik()
    end
  end

  defp post_deploy_hooks(%{domain: domain} = deployment)
       when is_binary(domain) and domain != "" do
    sync_domain_records(deployment)
    create_dns_records(deployment)
  end

  defp post_deploy_hooks(_deployment), do: :ok

  @doc """
  Brings the `Domain` rows for a deployment in line with the domain it is actually
  served at: retires rows for names it no longer answers to, and creates or reclaims
  the row for its current one.

  Public because it has two callers with nothing else in common — first deploy, and
  any later edit that moves the domain or changes the exposure.
  """
  def sync_domain_records(%Deployment{domain: domain} = deployment)
      when is_binary(domain) and domain != "" do
    deployment = Repo.preload(deployment, [:app_template])

    # The EFFECTIVE exposure, not the template's. This read `app_template.exposure_mode`
    # and ignored `exposure_mode_override`, so a deployment moved to :public kept a
    # Domain row claiming it was SSO-protected.
    exposure = Access.effective_exposure(deployment) || :public

    retire_stale_domains(deployment, domain)

    case Homelab.Networking.get_domain_by_fqdn(domain) do
      {:ok, existing} ->
        # Reclaim a row that already exists for this fqdn rather than leaving it
        # pointing at whatever created it.
        _ =
          Homelab.Networking.update_domain(existing, %{
            deployment_id: deployment.id,
            exposure_mode: exposure
          })

        :ok

      {:error, :not_found} ->
        case Homelab.Networking.create_domain(%{
               fqdn: domain,
               deployment_id: deployment.id,
               exposure_mode: exposure,
               tls_status: :pending
             }) do
          {:ok, _} ->
            ActivityLog.info("domain", "Created domain record for #{domain}", %{
              deployment_id: deployment.id
            })

          {:error, reason} ->
            ActivityLog.error(
              "domain",
              "Failed to create domain for #{domain}: #{inspect(reason)}",
              %{deployment_id: deployment.id}
            )
        end
    end
  end

  # A deployment with no domain answers to no name, so every row it holds is stale.
  def sync_domain_records(%Deployment{} = deployment),
    do: retire_stale_domains(deployment, nil)

  # Domains this deployment used to answer to and no longer does. Deleted rather than
  # left orphaned: the row carries TLS state and a DNS-zone link for a name this
  # deployment is not served at any more, and `unique_constraint(:fqdn)` means it would
  # otherwise sit on that name forever, blocking a legitimate reuse.
  defp retire_stale_domains(deployment, current_fqdn) do
    deployment.id
    |> Homelab.Networking.list_domains_for_deployment()
    |> Enum.reject(&(&1.fqdn == current_fqdn))
    |> Enum.each(fn stale ->
      case Homelab.Networking.delete_domain(stale) do
        {:ok, _} ->
          ActivityLog.info("domain", "Retired domain record for #{stale.fqdn}", %{
            deployment_id: deployment.id
          })

        {:error, reason} ->
          ActivityLog.error(
            "domain",
            "Failed to retire domain #{stale.fqdn}: #{inspect(reason)}",
            %{deployment_id: deployment.id}
          )
      end
    end)
  end

  defp create_dns_records(%{domain: domain} = deployment)
       when is_binary(domain) and domain != "" do
    ip_config = detect_ip_config()

    case Homelab.Networking.ensure_deployment_dns_records(deployment, ip_config) do
      {:ok, records} when records != [] ->
        ActivityLog.info("dns", "Created #{length(records)} DNS record(s) for #{domain}", %{
          deployment_id: deployment.id
        })

      {:ok, _} ->
        :ok

      {:error, reason} ->
        ActivityLog.error(
          "dns",
          "Failed to create DNS records for #{domain}: #{inspect(reason)}",
          %{deployment_id: deployment.id}
        )
    end
  end

  defp create_dns_records(_deployment), do: :ok

  @doc """
  The address deployment DNS records point at, used for both the internal and public
  scope.

  This used to be "the first non-loopback IPv4 `:inet.getifaddrs/0` returns", which on
  any host running containers includes the daemon's own bridges — so the A record for
  every app could come out as `172.17.0.1`, an address reachable from nowhere, decided
  by interface ordering. `Networking.host_ip/0` asks the routing table instead.

  Public only so `ReleaseSteps.PublishDns` uses the SAME answer the imperative
  `create_dns_records/1` uses. Two copies of "which IP does this host answer on"
  drifting apart would publish one address through `deploy_now/1` and a different one
  through the saga for the same deployment.
  """
  def detect_ip_config do
    host_ip = Homelab.Networking.host_ip()
    %{internal_ip: host_ip, public_ip: host_ip}
  end
end
