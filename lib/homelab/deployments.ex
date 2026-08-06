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
  alias Homelab.Deployments.{Access, ReleaseRunner, Releases}
  alias Homelab.Services.ActivityLog

  @doc """
  Executes an adoption/import plan — adopts existing containers in place as
  managed deployments. See `Homelab.Deployments.Adoption.apply_plan/2`.
  """
  defdelegate apply_adoption_plan(plan, opts), to: Homelab.Deployments.Adoption, as: :apply_plan

  def list_deployments do
    Deployment
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  def list_deployments_for_tenant(tenant_id) do
    Deployment
    |> where(tenant_id: ^tenant_id)
    |> preload([:app_template])
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

    if ingress_published?(deployment) and attachable?(deployment) do
      Homelab.Config.orchestrator().publish(deployment.external_id, ingress_network())
    else
      :ok
    end
  end

  # Whether this workload has a network endpoint that CAN be attached to another network.
  #
  # A container living in another container's namespace does not: the daemon refuses
  # `/networks/<n>/connect` on it with a 403 ("container sharing network namespace with
  # another container or host cannot be connected to any other network"). It is still
  # proxy-mode with a domain — a tunneled *arr app behind gluetun is exactly that — so
  # every other measure says it should be published, and attempting it would fail the
  # release's publish step and roll the whole deploy back.
  #
  # Its route is real, it is just served by its DONOR, which SpecBuilder multi-homes onto
  # ingress at create time via `bridge_networks`. There is nothing for this to do.
  defp attachable?(%Deployment{} = deployment) do
    not Netns.child?(deployment) and not Access.host_network_mode?(deployment)
  end

  # The network Traefik resolves backends on — the same one `SpecBuilder` writes into the
  # workload's `traefik.docker.network` label. Passed to the driver rather than assumed
  # by it, so a workload reached over a different network stays expressible.
  defp ingress_network, do: Homelab.Infrastructure.internal_network()

  @doc """
  Severs a deployment's public path by detaching its workload from the shared ingress
  network — Traefik loses the backend address and stops routing to it.

  Always safe to call: detaching something already detached is a no-op, so this also
  cleans up a stale route after an access-mode change.
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

  @doc "Lists all ingress-published deployments (any status), preloaded."
  def list_ingress_deployments do
    Deployment
    |> where([d], not is_nil(d.domain) and d.domain != "")
    |> preload([:tenant, :app_template])
    |> Repo.all()
  end

  @doc "Lists ingress-published deployments currently in `:running`, preloaded."
  def list_published_running do
    Deployment
    |> where([d], d.status == :running and not is_nil(d.domain) and d.domain != "")
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

  def stop_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if deployment.external_id do
      _ = Homelab.Config.orchestrator().undeploy(deployment.external_id)
    end

    update_deployment(deployment, %{status: :stopped, external_id: nil})
  end

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

  def restart_deployment(%Deployment{} = deployment) do
    if deployment.external_id do
      case Homelab.Config.orchestrator().restart(deployment.external_id) do
        :ok ->
          update_status(deployment, :deploying)

        {:error, _reason} ->
          {:error, :restart_failed}
      end
    else
      {:error, :not_deployed}
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
  Applies a deployment's current config (domain, ports, exposure, env) to its
  running workload. Pass the deployment AFTER persisting any config changes; the
  new spec is rebuilt from the row by `SpecBuilder.build/1`.

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

  # A no-op for rows the caller already loaded — which is all of them on the common
  # path, where re-fetching by id would query the same deployment three times.
  defp with_associations(%Deployment{} = deployment),
    do: Repo.preload(deployment, [:tenant, :app_template])

  @doc """
  Provisions a deployment (and any companion deployments) durably via the release
  saga instead of the imperative in-request path: plans the ordered steps and
  enqueues `ReleaseRunner`. Companions are deployed and awaited healthy before the
  app, the app is awaited, then ingress is published (when the app has a domain).

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
    steps =
      ingress_proxy_steps(app) ++
        Enum.flat_map(companion_set(app, companions), fn companion ->
          [
            %{type: :dependency_container, resource_handle: %{"deployment_id" => companion.id}},
            %{type: :await_health, resource_handle: %{"deployment_id" => companion.id}}
          ] ++ datastore_grant_steps(app, companion)
        end) ++
        [
          %{type: :app_container, resource_handle: %{}},
          %{type: :await_health, resource_handle: %{}}
        ] ++ ingress_steps(app)

    Releases.plan_release(app, steps)
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

  # Does this deployment answer to a name of its OWN? Distinct from `routed?/1`, and
  # the distinction is the netns donor: a name is a property of the deployment that
  # holds it, while reachability is a property of the container Traefik can resolve,
  # and for a tunneled stack those are two different deployments.
  defp own_domain?(%Deployment{domain: domain}), do: is_binary(domain) and domain != ""

  # Does traffic from the proxy reach this deployment? The ONE definition of "routed",
  # because several step lists key off it and a second inlined copy is exactly how a
  # plan ends up ensuring a proxy for a release that never publishes a route.
  #
  # A donor with routed children is routed even with no domain of its own — which is
  # the ordinary gluetun shape, where every name in the stack belongs to a child. This
  # is not a widening for its own sake: `SpecBuilder` already emits `traefik.enable` and
  # multi-homes that donor onto the ingress network, because a child has no endpoint for
  # Traefik to discover and its route resolves to the DONOR's address. Reading only
  # `domain` planned no proxy and no ingress for the one topology that needs both.
  #
  # Matched to SpecBuilder's rule exactly, `Access.proxy_mode?` included: a donor whose
  # children are `:service` or `:host` is not multi-homed there either, and publishing
  # ingress for it would attach a container Traefik has no labels for.
  defp routed?(%Deployment{} = deployment) do
    own_domain?(deployment) or Enum.any?(Netns.children(deployment), &routes_via_donor?/1)
  end

  # `Access.proxy_mode?/1` reads the template, and a caller's preloaded
  # `:network_children` is not guaranteed to carry one — `Repo.preload/2` on an
  # already-loaded association is a no-op, so this is only a cost when it is needed.
  # Short-circuits on `own_domain?/1`, which is a plain field read.
  defp routes_via_donor?(%Deployment{} = child),
    do: own_domain?(child) and Access.proxy_mode?(Repo.preload(child, :app_template))

  # The proxy has to exist before anything that routes through it. Planned at position
  # 1, ahead of every container: it is a precondition of the route, not a product of
  # it, and failing there means no container has been created yet. See
  # `ReleaseSteps.EnsureIngressProxy` for why it has no compensation.
  defp ingress_proxy_steps(app) do
    if routed?(app), do: [%{type: :ensure_ingress_proxy, resource_handle: %{}}], else: []
  end

  # Claiming a NAME: the local `Domain` row and the A records that resolve it. Keyed off
  # `own_domain?/1`, not `routed?/1` — these belong to whichever deployment holds the
  # domain, which for a tunneled stack is the child, not the donor carrying its route.
  # `handle` targets them; an empty handle means the release's own deployment.
  defp name_steps(deployment, handle \\ %{}) do
    if own_domain?(deployment) do
      [
        %{type: :sync_domain, resource_handle: handle},
        %{type: :publish_dns, resource_handle: handle}
      ]
    else
      []
    end
  end

  # Granting REACHABILITY: attaching the workload to the shared ingress network so
  # Traefik can resolve it.
  #
  # The condition is `publish_deployment/1`'s OWN runtime gate, reused verbatim rather
  # than approximated, so that planned implies acted. Three shapes are proxy-routed by
  # every other measure and still cannot be attached, and each was previously planned a
  # step that fell through to `:ok` while recording `"published" => true`:
  #
  #   * a netns CHILD holding its own domain — the Sonarr-behind-gluetun shape. Its route
  #     is real and is served by its DONOR, which `SpecBuilder` multi-homes onto ingress
  #     via `bridge_networks` at create time. (`attachable?/1`)
  #   * a `:host_network` deployment — a container in the host namespace has no endpoint
  #     on any user-defined network. (`attachable?/1`)
  #   * a `:service`/`:host` deployment carrying a stray domain — not proxy-routed at all.
  #     (`ingress_published?/1`, via `Access.proxy_mode?/1`)
  #
  # A domainless donor with routed children is the fourth: genuinely routed, but it holds
  # no name of its own, so `ingress_published?/1` is false and its ingress membership
  # comes from `bridge_networks` too.
  #
  # Any predicate narrower than the runtime gate re-opens this, because the question
  # "will this step do anything" has exactly one correct answer and it already lives in
  # `publish_deployment/1`. A step that reports success for work it did not do is the
  # defect class this tier exists to remove.
  #
  # `ensure_ingress_proxy` deliberately does NOT share this gate: the proxy must exist
  # for a child's route whether or not the donor is itself attachable.
  #
  # Reusing the gate means reusing its PRELOAD too. `publish_deployment/1` opens with
  # `Repo.preload(deployment, [:tenant, :app_template])` before it evaluates either
  # predicate, because `Access.effective_exposure/1` reads the template. Restating the
  # predicates without it gave `deploy_release/2` a precondition its pre-image (a plain
  # `domain` field match) never had, and failed it by RAISING `KeyError :exposure_mode`
  # on the caller's struct — for a struct `publish_deployment/1` itself accepts.
  # `Repo.preload/2` on an already-loaded association is a no-op, so this costs nothing
  # on the common path.
  defp reachability_steps(deployment) do
    deployment = with_associations(deployment)

    if ingress_published?(deployment) and attachable?(deployment),
      do: [%{type: :publish_ingress, resource_handle: %{}}],
      else: []
  end

  # The tail of a routed release, all of it after the app is healthy: claim the name
  # locally, publish it to DNS, then actually grant reachability. Ordered so nothing
  # advertises a name before something answers to it, and so compensation (which walks
  # descending) severs reachability first, then DNS, then the row.
  defp ingress_steps(app) do
    name_steps(app) ++ reachability_steps(app)
  end

  @doc false
  # Reconciles the app's credentials against a datastore companion, AFTER that companion
  # is healthy and BEFORE the app starts.
  #
  # `EnsureDatastoreGrants` was registered, implemented and tested at the SQL level, and
  # no planner ever emitted it — so `Grants.reconcile/1` had exactly one caller and that
  # caller was unreachable. The bug it exists for is real and quiet: a datastore whose
  # volume already holds data ignores MARIADB_USER/PASSWORD (the image's init runs once,
  # on an empty data dir), so the app is handed a password the database never took. The
  # release still reaches `:running`, because `AwaitHealth` only checks that the
  # container is healthy — and the failure surfaces later as `Access denied` from inside
  # the app.
  #
  # Only for engines `Grants` can actually drive; anything else is left alone rather
  # than planned as a step that would fail.
  #
  # Note `ProvisionCredentials` is deliberately still unplanned. It is the other half of
  # this seam, but the deploy wizard already generates and shares the credential pair by
  # writing it into both deployments' `env_overrides` (`wire_db_secrets`). Planning
  # `ProvisionCredentials` as well would generate a SECOND, different password and hand
  # the two sides mismatched values — worse than the gap it would close.
  defp datastore_grant_steps(%Deployment{} = app, %Deployment{} = companion) do
    companion = Repo.preload(companion, :app_template)

    case Homelab.Deployments.Datastore.Grants.engine_for_image(companion.app_template.image) do
      {:ok, _engine} ->
        [
          %{
            type: :ensure_datastore_grants,
            resource_handle: %{
              "deployment_id" => companion.id,
              "app_deployment_id" => app.id
            }
          }
        ]

      {:error, _unsupported} ->
        []
    end
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
  touch the donor, so `recreate_deployment/1` is both sufficient and much cheaper.
  """
  def redeploy_netns_stack(%Deployment{} = deployment) do
    donor =
      case Netns.donor(deployment) do
        nil -> deployment
        parent -> parent
      end

    # Children carry their templates: `routed?/1` reads each child's effective exposure
    # to decide whether the donor needs ingress at all, and a shallow preload would make
    # that one query per child.
    donor =
      Repo.preload(donor, [:tenant, :app_template, network_children: [:app_template, :tenant]])

    children = Netns.children(donor)

    child_steps =
      Enum.flat_map(children, fn child ->
        [
          %{type: :netns_child_container, resource_handle: %{"deployment_id" => child.id}},
          %{type: :await_health, resource_handle: %{"deployment_id" => child.id}}
        ]
      end)

    # Each child's OWN name, published after that child is healthy.
    #
    # These used to be absent entirely: the routing steps all carried an empty handle,
    # so they targeted the donor, and a child in a redeployed stack got no `Domain` row
    # and no A record — while the same child deployed standalone through
    # `deploy_release/2` got both. That gap sat on the operation most likely to need
    # them: a stack redeploy is usually TRIGGERED by a child's route changing, since a
    # child's Traefik labels live on the donor. So the one path that moves a child's
    # name was the one that never republished it.
    child_name_steps =
      Enum.flat_map(children, &name_steps(&1, %{"deployment_id" => &1.id}))

    # Ingress LAST, after the children exist.
    #
    # The donor's Traefik labels serve the CHILDREN's routes — that is the whole reason
    # a child's route change re-creates the donor. Publishing before the children were
    # (re)created advertised every one of those routes to a namespace holding nothing
    # yet, so the window between "donor healthy" and "last child healthy" served 502s on
    # names that had been working a moment earlier. The proxy still goes first: it is a
    # precondition, not an advertisement.
    steps =
      ingress_proxy_steps(donor) ++
        [
          %{type: :app_container, resource_handle: %{}},
          %{type: :await_health, resource_handle: %{}}
        ] ++ child_steps ++ child_name_steps ++ ingress_steps(donor)

    with {:ok, donor} <- reset_to_pending(donor),
         {:ok, _children} <- reset_all_to_pending(children),
         {:ok, release} <- Releases.plan_release(donor, steps) do
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
  """
  def redeploy(%Deployment{} = deployment) do
    case Releases.driving_release(deployment.id) do
      nil ->
        with {:ok, app} <- reset_to_pending(deployment) do
          deploy_release(app)
        end

      %{__struct__: Homelab.Deployments.Release} = release ->
        if Homelab.Deployments.Release.terminal?(release) do
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
        else
          {:error, :release_active}
        end
    end
  end

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
    case Homelab.Infrastructure.ensure_traefik() do
      {:ok, :already_running} ->
        :ok

      {:ok, :started} ->
        ActivityLog.info("infrastructure", "Traefik started")

      {:error, reason} ->
        ActivityLog.error("infrastructure", "Traefik failed: #{inspect(reason)}")
    end
  end

  defp ensure_traefik_if_needed(_deployment), do: :ok

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
  The address deployment DNS records point at: this host's first non-loopback IPv4,
  used for both the internal and public scope.

  Public only so `ReleaseSteps.PublishDns` can use the SAME guess the imperative
  `create_dns_records/1` uses. Two copies of "which IP does this host answer on"
  drifting apart would publish one address through `deploy_now/1` and a different one
  through the saga for the same deployment.
  """
  def detect_ip_config do
    internal_ip = get_host_lan_ip()
    %{internal_ip: internal_ip, public_ip: internal_ip}
  end

  defp get_host_lan_ip do
    case :inet.getifaddrs() do
      {:ok, addrs} ->
        addrs
        |> Enum.flat_map(fn {_iface, opts} ->
          opts
          |> Keyword.get_values(:addr)
          |> Enum.filter(&(tuple_size(&1) == 4))
          |> Enum.reject(&(&1 == {127, 0, 0, 1}))
        end)
        |> List.first()
        |> case do
          nil -> nil
          ip -> ip |> :inet.ntoa() |> to_string()
        end

      _ ->
        nil
    end
  end
end
