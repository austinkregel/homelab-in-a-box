defmodule Homelab.Services.Reconciler do
  @moduledoc """
  Continuous control loop that makes deployment state fail-closed and self-healing.

  Every tick (and on every Docker event-stream reconnect) it:

    1. **Converges** each tracked deployment's status to the actual container
       state, using the readiness model (a template-declared healthcheck, else a
       running-and-stable window). This is what un-sticks `:deploying`.
    2. **Times out** deployments stuck in `:deploying` and marks them `:failed`.
    3. **Enforces the ingress invariant**: Traefik is connected to an
       ingress-published deployment's network *iff* it is `:running`. This is the
       only thing that grants external reachability, and it is idempotent.
    4. **Sweeps orphans**: a managed container with no deployment record has its
       public route severed immediately and is removed after a grace period.
    5. **Audits external bypasses**: deployments reachable via host ports (not
       Traefik) raise an admin alert.

  Every containment action alerts admins (activity log + notification). The loop
  never severs a workload container's internal/mesh networks — internal
  reachability is whatever Docker network membership allows; only the public
  (Traefik) path is ever cut here.
  """

  use GenServer
  require Logger

  alias Homelab.Accounts
  alias Homelab.Deployments
  alias Homelab.Deployments.SpecBuilder
  alias Homelab.Notifications
  alias Homelab.Services.ActivityLog

  @pubsub_topic "deployments:status"
  @default_interval_ms 20_000
  @deploying_timeout_ms 120_000
  @orphan_grace_ms 120_000
  @stable_ms 10_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Requests an out-of-band reconcile. Safe to call when not running (no-op)."
  def request_sync do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, :request_sync)
    end
  end

  @doc "Runs a reconcile synchronously and returns when complete. For tests/ops."
  def sync_now(timeout \\ 5_000) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.call(pid, :sync, timeout)
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, cfg(:interval_ms, @default_interval_ms))

    state = %{
      interval: interval,
      orphans: %{},
      flagged_bypass: MapSet.new()
    }

    if is_integer(interval), do: schedule_tick(interval)
    {:ok, state, {:continue, :initial_sync}}
  end

  @impl true
  def handle_continue(:initial_sync, state) do
    {:noreply, reconcile(state)}
  end

  @impl true
  def handle_info(:tick, state) do
    state = reconcile(state)
    schedule_tick(state.interval)
    {:noreply, state}
  end

  def handle_info(:sync, state), do: {:noreply, reconcile(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def handle_cast(:request_sync, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_call(:sync, _from, state) do
    {:reply, :ok, reconcile(state)}
  end

  defp schedule_tick(interval) when is_integer(interval) do
    Process.send_after(self(), :tick, interval)
  end

  # --- Reconcile pass ---

  defp reconcile(state) do
    case Homelab.Config.orchestrator() do
      nil ->
        state

      orchestrator ->
        case orchestrator.list_services() do
          {:ok, services} ->
            managed =
              Enum.filter(services, &(Map.get(&1.labels, "homelab.managed") == "true"))

            actual_by_id = Map.new(managed, &{&1.id, &1})

            converge(actual_by_id)
            sweep_deploying_timeouts()
            enforce_ingress_invariant()

            state
            |> sweep_orphans(orchestrator, managed)
            |> audit_external_bypass()

          {:error, reason} ->
            Logger.error("[Reconciler] list_services failed: #{inspect(reason)}")
            state
        end
    end
  end

  # 1. Status convergence
  defp converge(actual_by_id) do
    Deployments.list_desired_states()
    |> Enum.each(fn deployment ->
      converge_one(deployment, Map.get(actual_by_id, deployment.external_id))
    end)
  end

  defp converge_one(%{external_id: nil}, _service), do: :ok

  defp converge_one(deployment, nil) do
    # Container is gone. If we still expected it up, fail closed.
    if deployment.status in [:deploying, :running] do
      transition(deployment, :failed, [:deploying, :running], error: "Container not found")

      alert(
        :error,
        "Deployment container missing",
        "#{label(deployment)}: container #{deployment.external_id} no longer exists; marked failed.",
        deployment.id
      )
    end
  end

  defp converge_one(deployment, service) do
    case service.state do
      :running ->
        if ready?(deployment, service) do
          transition(deployment, :running, [:pending, :deploying])
        else
          demote_if_running(deployment)
        end

      :stopped ->
        transition(deployment, :stopped, [:deploying, :running])

      :failed ->
        transition(deployment, :failed, [:deploying, :running],
          error: "Container reported failed"
        )

      # :pending == created/restarting; leave it in :deploying to be retried/timed out.
      _ ->
        :ok
    end
  end

  # A previously-running deployment that is no longer ready (e.g. went unhealthy)
  # is demoted so the ingress invariant will sever its route this same pass.
  defp demote_if_running(deployment) do
    if deployment.status == :running do
      transition(deployment, :deploying, [:running])

      alert(
        :warning,
        "Deployment no longer ready",
        "#{label(deployment)} stopped reporting healthy; route severed until it recovers.",
        deployment.id
      )
    end
  end

  # 2. Deploying timeout
  defp sweep_deploying_timeouts do
    Deployments.list_desired_states()
    |> Enum.filter(&(&1.status == :deploying))
    |> Enum.each(fn deployment ->
      if age_ms(deployment.updated_at) >= deploying_timeout_ms() do
        transition(deployment, :failed, [:deploying], error: "Deploy timed out")

        alert(
          :error,
          "Deploy timed out",
          "#{label(deployment)} did not become ready within #{div(deploying_timeout_ms(), 1000)}s; marked failed and route severed.",
          deployment.id
        )
      end
    end)
  end

  # 3. Ingress invariant — the single, idempotent owner of external reachability.
  defp enforce_ingress_invariant do
    Deployments.list_ingress_deployments()
    |> Enum.each(fn deployment ->
      if deployment.status == :running do
        Deployments.publish_deployment(deployment)
      else
        Deployments.unpublish_deployment(deployment)
      end
    end)
  end

  # 4. Orphan sweep
  defp sweep_orphans(state, orchestrator, managed) do
    desired_ids = MapSet.new(Deployments.list_all_external_ids())
    orphans = Enum.reject(managed, &MapSet.member?(desired_ids, &1.id))
    now = System.monotonic_time(:millisecond)
    grace = orphan_grace_ms()

    new_orphans =
      Enum.reduce(orphans, %{}, fn container, acc ->
        case Map.get(state.orphans, container.id) do
          nil ->
            sever_orphan_route(orchestrator, container)

            alert(
              :warning,
              "Orphaned container detected",
              "Container #{container.name} (#{container.id}) has no deployment record; its public route was severed and it will be removed after the grace period.",
              nil
            )

            Map.put(acc, container.id, now)

          first_seen when now - first_seen >= grace ->
            _ = orchestrator.undeploy(container.id)

            alert(
              :error,
              "Orphaned container removed",
              "Removed orphaned container #{container.name} (#{container.id}) after grace period.",
              nil
            )

            acc

          first_seen ->
            Map.put(acc, container.id, first_seen)
        end
      end)

    %{state | orphans: new_orphans}
  end

  defp sever_orphan_route(orchestrator, %{labels: labels}) do
    tenant = labels["homelab.tenant"]
    app = labels["homelab.app"]

    if is_binary(tenant) and is_binary(app) do
      orchestrator.unpublish(SpecBuilder.deployment_network_for(tenant, app))
    else
      :ok
    end
  end

  # 5. External-bypass audit (alert once per deployment)
  defp audit_external_bypass(state) do
    new_flagged =
      Deployments.list_desired_states()
      |> Enum.reduce(state.flagged_bypass, fn deployment, flagged ->
        if deployment.status == :running and has_host_ports?(deployment.app_template) and
             not MapSet.member?(flagged, deployment.id) do
          alert(
            :warning,
            "External port bypass",
            "#{label(deployment)} publishes host ports, which are reachable without going through Traefik. Consider routing via Traefik instead.",
            deployment.id
          )

          MapSet.put(flagged, deployment.id)
        else
          flagged
        end
      end)

    %{state | flagged_bypass: new_flagged}
  end

  defp has_host_ports?(%{exposure_mode: :service}), do: false

  defp has_host_ports?(template) do
    Enum.any?(template.ports || [], &(&1["published"] == true))
  end

  # --- Readiness ---

  defp ready?(deployment, service) do
    if SpecBuilder.declares_healthcheck?(deployment.app_template) do
      case Map.get(service, :health, :none) do
        :healthy -> true
        h when h in [:starting, :unhealthy] -> false
        # Health unknown (e.g. Swarm doesn't surface it): fall back to stability.
        :none -> stable?(deployment)
      end
    else
      stable?(deployment)
    end
  end

  defp stable?(deployment), do: age_ms(deployment.updated_at) >= stable_ms()

  # Timing windows are overridable via `config :homelab, :reconciler` (used by tests).
  defp deploying_timeout_ms, do: cfg(:deploying_timeout_ms, @deploying_timeout_ms)
  defp orphan_grace_ms, do: cfg(:orphan_grace_ms, @orphan_grace_ms)
  defp stable_ms, do: cfg(:stable_ms, @stable_ms)

  defp cfg(key, default) do
    :homelab
    |> Application.get_env(:reconciler, [])
    |> Keyword.get(key, default)
  end

  defp age_ms(nil), do: 0

  defp age_ms(%NaiveDateTime{} = t),
    do: NaiveDateTime.diff(NaiveDateTime.utc_now(), t, :millisecond)

  defp age_ms(%DateTime{} = t), do: DateTime.diff(DateTime.utc_now(), t, :millisecond)

  # --- DB transition + broadcast ---

  defp transition(deployment, to, from_states, opts \\ []) do
    case Deployments.transition_status(deployment, to, from_states, opts) do
      {:ok, _updated} ->
        broadcast(deployment.id, to)
        :ok

      {:noop, _} ->
        :ok
    end
  end

  defp broadcast(deployment_id, status) do
    Phoenix.PubSub.broadcast(
      Homelab.PubSub,
      @pubsub_topic,
      {:deployment_status, deployment_id, status}
    )
  end

  # --- Alerting ---

  defp alert(level, title, body, deployment_id) do
    meta = if deployment_id, do: %{deployment_id: deployment_id}, else: %{}
    log_level = if level == :error, do: :error, else: :warn
    apply(ActivityLog, log_level, ["reconciler", "#{title}: #{body}", meta])

    severity = if level == :error, do: "error", else: "warning"
    notify_admins(title, body, severity)
    :ok
  end

  defp notify_admins(title, body, severity) do
    for user <- Accounts.list_admins() do
      Notifications.create(%{user_id: user.id, title: title, body: body, severity: severity})
    end

    :ok
  rescue
    _ -> :ok
  end

  defp label(deployment) do
    cond do
      is_binary(deployment.domain) and deployment.domain != "" ->
        deployment.domain

      match?(%{app_template: %{name: name}} when is_binary(name), deployment) ->
        deployment.app_template.name

      true ->
        "deployment ##{deployment.id}"
    end
  end
end
