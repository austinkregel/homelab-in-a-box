defmodule Homelab.Deployments.Adoption do
  @moduledoc """
  Executes an adoption plan (from `AdoptionPlanner.build_plan/1`): for each
  selected service it upserts a managed `AppTemplate`, gets-or-creates a pending
  `Deployment`, plans a per-service release (phase1 ++ phase2), and enqueues the
  `ReleaseRunner` to drive the in-place cutover.

  Safety properties:

    * The deployment is created `:pending` with `external_id: nil`, so it is
      invisible to the reconciler's converge/orphan-sweep paths until the cutover
      persists the managed container id.
    * One release per service — a failure isolates to that service.
    * Idempotent re-run: the template is upserted by slug, the deployment is
      reused, and a terminal (rolled-back/failed) prior release does not block a
      retry. An in-flight release does.
  """

  alias Homelab.Repo
  alias Homelab.Catalog
  alias Homelab.Deployments
  alias Homelab.Deployments.{Deployment, ReleaseRunner, Releases}

  @doc """
  Applies `plan` for `opts[:tenant_id]`. Returns `{:ok, results}` where each
  result is `%{service: name, deployment: %Deployment{}, release: %Release{}}`, or
  `{:error, {service_name, reason}}` on the first service that fails (services
  applied before it are already enqueued and keep running).
  """
  def apply_plan(%{services: services}, opts) when is_list(services) do
    tenant_id = Keyword.fetch!(opts, :tenant_id)

    # `adopted` maps each service's ORIGINAL container id to the deployment now adopting
    # it, which is the only way to turn a child's `network_mode: container:<id>` into a
    # `network_parent_id`. The planner orders donors first so the lookup can succeed.
    Enum.reduce_while(services, {:ok, [], %{}}, fn service, {:ok, acc, adopted} ->
      case apply_service(service, tenant_id, adopted) do
        {:ok, result} ->
          {:cont, {:ok, [result | acc], record_adopted(adopted, service, result)}}

        {:error, reason} ->
          {:halt, {:error, {service.name, reason}}}
      end
    end)
    |> case do
      {:ok, results, _adopted} -> {:ok, Enum.reverse(results)}
      {:error, _} = err -> err
    end
  end

  defp record_adopted(adopted, service, %{deployment: deployment}) do
    case Map.get(service, :container_id) do
      nil -> adopted
      container_id -> Map.put(adopted, container_id, deployment)
    end
  end

  # Steps run sequentially (not in one outer transaction): the template upsert is
  # idempotent, the deployment is reused on re-run, and `plan_release/3` wraps its
  # own writes — so a mid-way failure leaves a safe, re-runnable partial state.
  defp apply_service(service, tenant_id, adopted) do
    with {:ok, donor} <- resolve_netns_donor(service, adopted),
         {:ok, template} <- upsert_template(service.template_attrs),
         {:ok, deployment} <-
           get_or_create_deployment(
             tenant_id,
             template.id,
             netns_attrs(service[:deployment_attrs] || %{}, donor)
           ),
         :ok <- ensure_no_active_release(deployment.id),
         {:ok, release} <- plan(deployment, steps(service, donor, deployment), service) do
      # Enqueue after the release is committed (Oban lives on ObanRepo; the worker
      # must be able to read the release row). A failed enqueue is logged, not raised:
      # the release is already committed, so raising would abort an adoption that in
      # fact succeeded, and the reconciler re-enqueues an unleased release anyway.
      ReleaseRunner.enqueue_or_log(release)
      {:ok, %{service: service.name, deployment: deployment, release: release}}
    end
  end

  # Which deployment owns the namespace this service's original lived in.
  #
  # Resolved from the services already applied in THIS plan, matched on the original
  # container id. That is the only correspondence available: an adopted donor's
  # `external_id` is its NEW managed container, so there is nothing on the row that still
  # points back at the original id a child's `NetworkMode` names.
  #
  # Which is why a donor outside the plan is still refused. Adopting the child anyway
  # would put it on the tenant network instead of inside the tunnel, so an app whose
  # entire purpose is that none of its traffic escapes the VPN would start sending all of
  # it straight out while reporting a successful adoption. There is no state in between.
  # The refusal now says what to do about it.
  defp resolve_netns_donor(service, adopted) do
    case Map.get(service, :netns_parent_container_id) do
      nil ->
        {:ok, nil}

      container_id ->
        case find_adopted(adopted, container_id) do
          nil -> {:error, {:netns_donor_not_selected, container_id}}
          donor -> {:ok, donor}
        end
    end
  end

  # Docker reports the full 64-character id in `NetworkMode`, and discovery captures the
  # full id too, so this is normally an exact hit. Prefix-matched either way, because a
  # short id anywhere in the chain would otherwise read as "donor not selected" and refuse
  # an import that was perfectly well specified.
  defp find_adopted(adopted, container_id) do
    Enum.find_value(adopted, fn {adopted_id, deployment} ->
      if id_match?(adopted_id, container_id), do: deployment
    end)
  end

  defp id_match?(a, b) when is_binary(a) and is_binary(b) do
    a == b or String.starts_with?(a, b) or String.starts_with?(b, a)
  end

  defp id_match?(_a, _b), do: false

  defp netns_attrs(attrs, nil), do: attrs
  defp netns_attrs(attrs, donor), do: Map.put(attrs, :network_parent_id, donor.id)

  # The full ordered plan for one service: the planner's pure phases, wrapped in the
  # ROUTING steps the other two planners already emit.
  #
  # `AdoptionPlanner` cannot build these itself — it is pure by construction and the
  # `Deployment` row does not exist until `get_or_create_deployment/3` above has run, and
  # the routing predicates are all reads of that row (its domain, its effective exposure,
  # its netns children). So they are composed here, from `Deployments`' own builders, and
  # the predicate has exactly one definition.
  #
  # ## Why the proxy goes first and the name goes last
  #
  # `ensure_ingress_proxy` at position 1, matching greenfield: the proxy is a
  # precondition of the route, not a product of it. In an adoption that is also the
  # cheapest possible place to fail — ahead of `backup_verify`, so nothing has been
  # quiesced, copied or cut over and there is nothing to unwind.
  #
  # The name (`sync_domain`, `publish_dns`) and reachability (`publish_ingress`) go at
  # the very END, after `verify_integrity`. Adoption IS a cutover, but the name is not
  # one the plane already holds: before adoption there is no `Domain` row and no
  # plane-written A record — that absence is the gap being closed — so these steps are a
  # first claim, not a re-point, and there is no continuity to preserve by publishing
  # early. Publishing early is strictly worse in three ways:
  #
  #   * `quiesce_old` deliberately STOPS the original for the length of the data copy.
  #     A name advertised in phase 1 resolves, through that whole window, to a proxy
  #     with no backend — and resolvers cache it.
  #   * between phase 1 and `adopt_container` the managed container does not exist at
  #     all. `redeploy_netns_stack/1` already makes this argument for its own ingress
  #     step: publishing before the workload exists serves 502s on a working name.
  #   * `sync_domain`'s first act is `retire_stale_domains/2`, which DELETES this
  #     deployment's rows for every other name. Running that before the cutover has
  #     proven the replacement can serve destroys domain state for a workload that may
  #     then roll back.
  #
  # `verify_integrity` is adoption's proof that the managed container came up on the
  # migrated data. Claiming the name after it means the name is never advertised for
  # something unproven.
  #
  # ## What this means on ROLLBACK
  #
  # Compensation walks descending, so the undo order is: detach ingress, delete the A
  # records, delete the `Domain` row, and only then unwind the cutover back to the
  # original container. That is the correct direction — reachability is severed before
  # the backend it points at is taken away.
  #
  # The DNS delete is safe here for one specific reason, and it is worth stating because
  # the alternative is catastrophic: an adoption that rolls back must leave the ORIGINAL
  # serving, so a compensation that deleted the record the original is reached at would
  # be worse than never adopting. It does not: `PublishDns.compensate/2` deletes only
  # records its own `run/2` CREATED, never one it merely upserted over. A name the
  # operator was already resolving survives the rollback, exactly as `SyncDomain` already
  # refuses to delete a `Domain` row it only reclaimed.
  defp steps(service, donor, deployment) do
    Deployments.ingress_proxy_steps(deployment) ++
      service.phase1 ++
      donor_barrier(donor) ++
      service.phase2 ++
      Deployments.ingress_steps(deployment)
  end

  defp donor_barrier(nil), do: []

  # The cutover embeds the donor's CONTAINER id in the child's create payload, so it
  # cannot run until the donor's managed container exists and is up. Adopting the donor
  # replaces its container, which is precisely why the child's original cannot simply be
  # left as it was.
  #
  # The wait goes at the top of PHASE 2, not phase 1: phase 1 copies this service's data
  # while everything is still running, and there is no reason to hold that behind the
  # donor. Blocking immediately before the step that needs the id keeps the two
  # migrations overlapping.
  #
  # A generous timeout because what it is waiting behind is another service's data copy,
  # which for a media library is minutes to hours — the 2-minute default would roll this
  # release back for no reason other than that the donor was big.
  defp donor_barrier(donor) do
    [
      %{
        type: :await_health,
        resource_handle: %{
          "deployment_id" => donor.id,
          "timeout_ms" => netns_donor_timeout_ms()
        }
      }
    ]
  end

  defp netns_donor_timeout_ms,
    do: Application.get_env(:homelab, :adoption_netns_donor_timeout_ms, 3_600_000)

  defp upsert_template(attrs) do
    case Catalog.get_app_template_by_slug(attrs.slug) do
      {:ok, template} -> Catalog.update_app_template(template, attrs)
      {:error, :not_found} -> Catalog.create_app_template(attrs)
    end
  end

  defp get_or_create_deployment(tenant_id, app_template_id, attrs) do
    case Repo.get_by(Deployment, tenant_id: tenant_id, app_template_id: app_template_id) do
      nil ->
        Deployments.create_deployment(
          Map.merge(attrs, %{
            tenant_id: tenant_id,
            app_template_id: app_template_id,
            status: :pending
          })
        )

      %Deployment{status: :running, external_id: ext} = _dep when is_binary(ext) ->
        {:error, :already_adopted}

      # A re-run reuses the existing row rather than reapplying `attrs`. The captured
      # properties describe the ORIGINAL container, and by now the operator may have
      # deliberately changed them -- a re-run should not quietly revert that.
      %Deployment{} = dep ->
        {:ok, dep}
    end
  end

  defp ensure_no_active_release(deployment_id) do
    if Releases.get_active_release(deployment_id), do: {:error, :release_in_flight}, else: :ok
  end

  defp plan(deployment, steps, service) do
    Releases.plan_release(deployment, steps,
      plan: %{
        "kind" => "adoption",
        "service" => service.name,
        "targets" => service.targets
      }
    )
  end
end
