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

    Enum.reduce_while(services, {:ok, []}, fn service, {:ok, acc} ->
      case apply_service(service, tenant_id) do
        {:ok, result} -> {:cont, {:ok, [result | acc]}}
        {:error, reason} -> {:halt, {:error, {service.name, reason}}}
      end
    end)
    |> case do
      {:ok, results} -> {:ok, Enum.reverse(results)}
      {:error, _} = err -> err
    end
  end

  # Steps run sequentially (not in one outer transaction): the template upsert is
  # idempotent, the deployment is reused on re-run, and `plan_release/3` wraps its
  # own writes — so a mid-way failure leaves a safe, re-runnable partial state.
  defp apply_service(service, tenant_id) do
    steps = service.phase1 ++ service.phase2

    with :ok <- refuse_netns_child(service),
         {:ok, template} <- upsert_template(service.template_attrs),
         {:ok, deployment} <-
           get_or_create_deployment(tenant_id, template.id, service[:deployment_attrs] || %{}),
         :ok <- ensure_no_active_release(deployment.id),
         {:ok, release} <- plan(deployment, steps, service) do
      # Enqueue after the release is committed (Oban lives on ObanRepo; the worker
      # must be able to read the release row).
      {:ok, _job} = ReleaseRunner.enqueue(release)
      {:ok, %{service: service.name, deployment: deployment, release: release}}
    end
  end

  # A container living in ANOTHER container's network namespace cannot be adopted yet,
  # and adopting it anyway is not a partial success — it is a leak.
  #
  # The replacement would come up on the tenant network instead of inside the tunnel,
  # so an app whose entire purpose is that none of its traffic escapes the VPN would
  # start sending all of it straight out, while reporting a successful adoption. There
  # is no state in between: either it is in the namespace or it is not.
  #
  # Adopting one properly needs cross-service resolution (the donor's container id maps
  # to whichever deployment is adopting THAT container) and cross-service ordering,
  # which `apply_service/2` — one service, one release, enqueued immediately — cannot
  # express. Until that exists, refuse where the damage would be done, and let the
  # operator re-create it through the deploy wizard, which does support this.
  defp refuse_netns_child(service) do
    case Map.get(service, :netns_parent_container_id) do
      nil -> :ok
      container_id -> {:error, {:netns_child_not_adoptable, container_id}}
    end
  end

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
