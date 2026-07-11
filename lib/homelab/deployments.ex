defmodule Homelab.Deployments do
  @moduledoc """
  Context for managing deployments.

  A deployment represents an instance of an app template running
  within a tenant's space.
  """

  import Ecto.Query
  alias Homelab.Repo
  alias Homelab.Deployments.Deployment
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
      {:ok, deployment} -> {:ok, Repo.preload(deployment, [:tenant, :app_template], force: true)}
      error -> error
    end
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
  True when a deployment *should* carry a public Traefik route: it's in a reverse-
  proxy access mode AND has a domain. `:host`/`:service` deployments are never
  proxied (a host deployment with a stray domain is not routed). Requires
  `app_template` preloaded.
  """
  def ingress_published?(%Deployment{} = deployment) do
    is_binary(deployment.domain) and deployment.domain != "" and Access.proxy_mode?(deployment)
  end

  @doc """
  Makes a proxy-mode deployment publicly reachable by connecting Traefik to its
  per-deployment network. No-op unless it's a proxy mode with a domain. This is
  the *only* action that grants external reachability.
  """
  def publish_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

    if ingress_published?(deployment) do
      network = SpecBuilder.deployment_network(deployment.tenant, deployment.app_template)
      Homelab.Config.orchestrator().publish(network)
    else
      :ok
    end
  end

  @doc """
  Severs a deployment's public path by disconnecting Traefik from its
  per-deployment network. Always safe to call (disconnecting a network Traefik
  isn't on is a no-op), so it also cleans up a stale route after an access-mode
  change. Never touches the workload container's own networks.
  """
  def unpublish_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])
    network = SpecBuilder.deployment_network(deployment.tenant, deployment.app_template)
    Homelab.Config.orchestrator().unpublish(network)
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

  def delete_deployment(%Deployment{} = deployment) do
    Repo.delete(deployment)
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

    case Homelab.Deployments.SpecBuilder.build(deployment) do
      {:ok, spec} ->
        case orchestrator.deploy(spec) do
          {:ok, external_id} ->
            case transition_status(
                   deployment,
                   :deploying,
                   [:pending, :deploying, :stopped, :failed],
                   external_id: external_id
                 ) do
              {:ok, _} -> :ok
              {:noop, _} -> ensure_external_id(deployment, external_id)
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
  """
  def destroy_deployment(%Deployment{} = deployment) do
    deployment = Repo.preload(deployment, [:tenant, :app_template])

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
  Recreates a deployment's container so config changes (domain, ports, exposure,
  env) take effect. Docker bakes those into the container at create time, so
  there is no in-place update — we undeploy the old container and deploy a fresh
  one from the (now-updated) row via `SpecBuilder.build/1`. Pass the deployment
  AFTER persisting any config changes. Safe when stopped/failed (no old container
  to remove).
  """
  def recreate_deployment(%Deployment{} = deployment) do
    with {:ok, stopped} <- stop_deployment(deployment) do
      start_deployment(stopped)
    end
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
  def deploy_release(%Deployment{} = app, companions \\ [], _opts \\ [])
      when is_list(companions) do
    steps =
      Enum.flat_map(companions, fn companion ->
        [
          %{type: :dependency_container, resource_handle: %{"deployment_id" => companion.id}},
          %{type: :await_health, resource_handle: %{"deployment_id" => companion.id}}
        ]
      end) ++
        [
          %{type: :app_container, resource_handle: %{}},
          %{type: :await_health, resource_handle: %{}}
        ] ++ ingress_steps(app)

    with {:ok, release} <- Releases.plan_release(app, steps) do
      {:ok, _job} = ReleaseRunner.enqueue(release)
      {:ok, release}
    end
  end

  defp ingress_steps(%Deployment{domain: domain}) when is_binary(domain) and domain != "",
    do: [%{type: :publish_ingress, resource_handle: %{}}]

  defp ingress_steps(_app), do: []

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

    case Homelab.Deployments.SpecBuilder.build(deployment) do
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
    exposure = deployment.app_template.exposure_mode || :public

    case Homelab.Networking.get_domain_by_fqdn(domain) do
      {:ok, _existing} ->
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

    create_dns_records(deployment)
  end

  defp post_deploy_hooks(_deployment), do: :ok

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

  defp detect_ip_config do
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
