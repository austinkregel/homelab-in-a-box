defmodule Homelab.Deployments.Reclaim do
  @moduledoc """
  Recovering deployments whose workload belongs to an orchestrator that is no longer the
  active one.

  Switching the orchestrator from Swarm to Engine strands every deployment created under
  Swarm. Its `external_id` is a Swarm SERVICE id, and the Engine driver looks that up as a
  container — `GET /containers/<service-id>/json` 404s, `list_services/0` (which filters on
  `homelab.managed=true`) cannot see the task containers either, and the reconciler marks a
  perfectly healthy deployment `:failed` with "Container not found". Meanwhile the workload
  is running fine, because Swarm is still maintaining it.

  ## Why this is a migration and not an adoption

  Pointing `external_id` at the running task container does not work. Swarm's own
  reconciler still owns that container: stop it and a new task replaces it within seconds,
  and every subsequent operation fights a controller that disagrees about desired state.
  There is no version of "adopt" that leaves two controllers in charge of one container.

  So the service is REMOVED and the workload recreated under the active orchestrator. The
  data survives because nothing touches the volumes — they are the same named volumes,
  referenced by name from a spec rebuilt out of the same deployment row.

  ## Ordering, which is the whole safety argument

  Remove the service, WAIT for its task containers to actually go, and only then deploy.

  Deploying first would leave two containers alive at once: the Engine driver names its
  container `homelab_<tenant>_<app>` while a Swarm task is
  `homelab_<tenant>_<app>.1.<task-id>`, so the name-conflict path that normally replaces a
  container never triggers. Both would mount the same named volumes — two writers on one
  database or media library, which is a worse outcome than the downtime this costs.

  ## Identity

  Matched on `external_id` against the live service list, and the task containers found via
  Docker's own `com.docker.swarm.service.id` label. Both are exact: no name reconstruction,
  no heuristic, nothing that can match the wrong workload. That matters because the
  operation removes things.

  Note the `homelab.*` labels are absent from Swarm-era task containers — they were written
  to the service and not the `ContainerSpec`, which is the bug that made this state
  invisible in the first place and is fixed for anything deployed since.
  """

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Deployment
  alias Homelab.Docker.Client
  alias Homelab.Repo

  @doc """
  Deployments whose `external_id` names a live Swarm service while something other than
  Swarm is the active orchestrator.

  Returns `[]` when Swarm IS active — nothing is stranded then, the driver that owns these
  workloads is the one in charge. Also `[]` when the daemon has no services or is not a
  swarm manager, which is the ordinary case and must not read as an error.
  """
  def stranded do
    if swarm_active?() do
      []
    else
      case service_index() do
        services when map_size(services) > 0 -> stranded_against(services)
        _ -> []
      end
    end
  end

  defp stranded_against(services) do
    Deployment
    |> Repo.all()
    |> Repo.preload([:tenant, :app_template])
    |> Enum.filter(&(&1.external_id != nil))
    |> Enum.flat_map(fn deployment ->
      case Map.get(services, deployment.external_id) do
        nil ->
          []

        service ->
          [
            %{
              deployment: deployment,
              service_id: deployment.external_id,
              service_name: service["name"],
              containers: task_containers(deployment.external_id)
            }
          ]
      end
    end)
  end

  @doc """
  Migrates one stranded deployment onto the active orchestrator.

  Removes the Swarm service, waits for its tasks to stop, then redeploys from the
  deployment row. Returns `{:ok, deployment}`, or `{:error, reason}` with the service left
  alone — a failure to remove must NOT fall through to a deploy, or the result is the
  two-writer state this whole module exists to avoid.
  """
  def reclaim(%Deployment{external_id: nil}), do: {:error, :nothing_to_reclaim}

  def reclaim(%Deployment{} = deployment) do
    service_id = deployment.external_id

    with :ok <- remove_service(service_id),
         :ok <- await_tasks_gone(service_id) do
      # Cleared FIRST, so a deploy that fails cannot leave the row pointing at a service
      # that no longer exists — which is the state that looks identical to being stranded
      # and would offer the operator a reclaim that can never work.
      {:ok, deployment} = Deployments.update_deployment(deployment, %{external_id: nil})

      case Deployments.recreate_deployment(deployment) do
        {:ok, _} ->
          Logger.info("[reclaim] #{deployment.id} migrated off swarm service #{service_id}")
          {:ok, Deployments.get_deployment!(deployment.id)}

        {:error, reason} ->
          {:error, {:redeploy_failed, reason}}
      end
    end
  end

  # `DELETE /services/<id>` directly rather than through the orchestrator behaviour: the
  # active driver is Engine by definition here, and its `undeploy/1` would issue
  # `DELETE /containers/<service-id>` and 404. The Swarm service is unreachable through the
  # selected driver, which is exactly why a deployment gets stranded.
  defp remove_service(service_id) do
    case Client.delete("/services/#{service_id}") do
      {:ok, _} -> :ok
      # Already gone. The goal is "this service is not running", and it is not.
      {:error, {:not_found, _}} -> :ok
      {:error, {:http_error, 404, _}} -> :ok
      {:error, reason} -> {:error, {:service_removal_failed, service_id, reason}}
    end
  end

  # Swarm removes tasks asynchronously, so the service disappearing does not mean the
  # container has. Deploying into that window is the two-writer case.
  defp await_tasks_gone(service_id) do
    deadline = System.monotonic_time(:millisecond) + task_timeout_ms()
    poll_tasks(service_id, deadline)
  end

  defp poll_tasks(service_id, deadline) do
    case task_containers(service_id) do
      [] ->
        :ok

      containers ->
        if System.monotonic_time(:millisecond) >= deadline do
          {:error, {:tasks_still_running, service_id, Enum.map(containers, & &1["Id"])}}
        else
          Process.sleep(task_interval_ms())
          poll_tasks(service_id, deadline)
        end
    end
  end

  @doc """
  The containers Docker says belong to a Swarm service.

  Via `com.docker.swarm.service.id`, which the daemon writes itself — the only label on a
  Swarm-era task container that identifies it, since ours never reached the `ContainerSpec`.
  """
  def task_containers(service_id) do
    filters = Jason.encode!(%{"label" => ["com.docker.swarm.service.id=#{service_id}"]})

    case Client.get("/containers/json?all=true&filters=#{URI.encode(filters)}") do
      {:ok, containers} when is_list(containers) -> containers
      _ -> []
    end
  end

  # `%{service_id => %{"name" => ...}}`, or `%{}` when the daemon is not a manager (a plain
  # Engine answers 503 "this node is not a swarm manager", which is not an error here).
  defp service_index do
    case Client.get("/services") do
      {:ok, services} when is_list(services) ->
        Map.new(services, fn service ->
          {service["ID"], %{"name" => get_in(service, ["Spec", "Name"])}}
        end)

      _ ->
        %{}
    end
  end

  defp swarm_active?,
    do: Homelab.Config.orchestrator() == Homelab.Orchestrators.DockerSwarm

  defp task_timeout_ms, do: Application.get_env(:homelab, :reclaim_task_timeout_ms, 60_000)
  defp task_interval_ms, do: Application.get_env(:homelab, :reclaim_task_interval_ms, 1_000)
end
