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
    4. **Sweeps orphans**: a managed container with no deployment record. The
       action taken depends on the `reconciler_sweep_mode` setting:
         * `sever_only` (default): sever the public route, notify, and record the
           orphan — but **never** delete the container. The user reviews and
           removes orphans by hand under Settings → Danger Zone.
         * `armed`: sever, then delete the container after a grace period. Arming
           resets every recorded orphan's grace clock, so nothing is deleted on
           the very next tick after switching modes.
         * `paused`: no orphan handling at all (severed routes are not enforced).
       The orphan registry is in-memory GenServer state (no persistence, no
       migration): after a restart the next pass re-discovers and re-severs
       orphans within one interval, and in `armed` mode the grace clock restarts —
       which is strictly safer than deleting sooner.
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
  alias Homelab.Deployments.{Access, ReleaseRunner, Releases, SpecBuilder}
  alias Homelab.Notifications
  alias Homelab.Services.ActivityLog
  alias Homelab.Settings

  @pubsub_topic "deployments:status"
  @default_interval_ms 20_000
  @deploying_timeout_ms 120_000
  @orphan_grace_ms 120_000
  @stable_ms 10_000
  @sweep_mode_setting "reconciler_sweep_mode"

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

  @doc """
  The currently-tracked orphaned containers (managed containers with no
  deployment record). Safe to call when the reconciler isn't running — returns
  `[]` — so LiveViews can render without depending on the GenServer.
  """
  def list_orphans do
    case Process.whereis(__MODULE__) do
      nil -> []
      pid -> GenServer.call(pid, :list_orphans)
    end
  end

  @doc """
  Manually removes a tracked orphan container now (the only delete path when the
  sweep is not `armed`). Returns `:ok`, `{:error, :not_orphaned}` for an unknown
  id, or `{:error, reason}` if the orchestrator undeploy fails.
  """
  def remove_orphan(container_id) do
    case Process.whereis(__MODULE__) do
      nil -> {:error, :not_orphaned}
      pid -> GenServer.call(pid, {:remove_orphan, container_id})
    end
  end

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval, cfg(:interval_ms, @default_interval_ms))

    state = %{
      interval: interval,
      orphans: %{},
      sweep_mode: :sever_only,
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

  def handle_call(:list_orphans, _from, state) do
    orphans =
      Enum.map(state.orphans, fn {id, entry} ->
        labels = entry.labels || %{}

        %{
          id: id,
          name: entry.name,
          detected_at: entry.detected_at,
          tenant: labels["homelab.tenant"],
          app: labels["homelab.app"]
        }
      end)

    {:reply, orphans, state}
  end

  def handle_call({:remove_orphan, container_id}, _from, state) do
    case Map.get(state.orphans, container_id) do
      nil ->
        {:reply, {:error, :not_orphaned}, state}

      entry ->
        case Homelab.Config.orchestrator().undeploy(container_id) do
          :ok ->
            alert(
              :error,
              "Orphaned container removed",
              "Removed orphaned container #{entry.name} (#{container_id}) manually by an administrator.",
              nil
            )

            {:reply, :ok, %{state | orphans: Map.delete(state.orphans, container_id)}}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
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

            # Deployments owned by an in-flight release are left to the saga.
            leased = Releases.leased_deployment_ids()

            resume_stuck_releases()
            converge(actual_by_id, leased)
            sweep_deploying_timeouts(leased)
            enforce_ingress_invariant()

            state
            |> sweep_orphans(orchestrator, managed, leased)
            |> audit_external_bypass()

          {:error, reason} ->
            Logger.error("[Reconciler] list_services failed: #{inspect(reason)}")
            state
        end
    end
  end

  # Resume releases whose lease has expired (e.g. the runner's node crashed). A
  # release with no live owner is re-enqueued; the runner reclaims it or, if it
  # had already failed mid-rollback, drives it to a terminal state. This is what
  # gives stuck `:pending`/in-flight deployments a convergence path.
  defp resume_stuck_releases do
    Releases.list_resumable_releases()
    |> Enum.each(&ReleaseRunner.enqueue/1)
  end

  # 1. Status convergence
  defp converge(actual_by_id, leased) do
    Deployments.list_desired_states()
    |> Enum.reject(&MapSet.member?(leased, &1.id))
    |> Enum.each(fn deployment ->
      converge_one(deployment, Map.get(actual_by_id, deployment.external_id))
      # Stamp the heartbeat so the UI reflects that this deployment was reconciled.
      Deployments.mark_reconciled(deployment)
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
  defp sweep_deploying_timeouts(leased) do
    Deployments.list_desired_states()
    |> Enum.reject(&MapSet.member?(leased, &1.id))
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
      # Traefik is connected iff the deployment is a proxy mode with a domain AND
      # running. Anything else with a (possibly stale) domain is disconnected.
      if Deployments.ingress_published?(deployment) and deployment.status == :running do
        Deployments.publish_deployment(deployment)
      else
        Deployments.unpublish_deployment(deployment)
      end
    end)
  end

  # 4. Orphan sweep. Behaviour depends on the sweep mode (see moduledoc).
  defp sweep_orphans(state, orchestrator, managed, leased) do
    mode = sweep_mode()

    case mode do
      :paused ->
        # Do nothing this pass; retain timestamps (grace resets on arming anyway).
        %{state | sweep_mode: :paused}

      _ ->
        desired_ids = MapSet.new(Deployments.list_all_external_ids())
        existing_ids = MapSet.new(Deployments.list_all_ids())

        orphans =
          managed
          |> Enum.reject(&MapSet.member?(desired_ids, &1.id))
          |> Enum.reject(&adoption_protected?(&1, leased, existing_ids))

        now = System.monotonic_time(:millisecond)
        grace = orphan_grace_ms()

        # Arming resets every recorded orphan's grace clock, so an orphan first
        # seen while in sever-only mode is not deleted on the first armed tick.
        prior =
          if mode == :armed and state.sweep_mode != :armed do
            Map.new(state.orphans, fn {id, entry} -> {id, %{entry | first_seen: now}} end)
          else
            state.orphans
          end

        new_orphans =
          Enum.reduce(orphans, %{}, fn container, acc ->
            case Map.get(prior, container.id) do
              nil ->
                sever_orphan_route(orchestrator, container)

                alert(
                  :warning,
                  "Orphaned container detected",
                  detected_body(container, mode),
                  nil
                )

                Map.put(acc, container.id, orphan_entry(container, now))

              %{first_seen: first_seen} = entry
              when mode == :armed and now - first_seen >= grace ->
                _ = orchestrator.undeploy(container.id)

                alert(
                  :error,
                  "Orphaned container removed",
                  "Removed orphaned container #{entry.name} (#{container.id}) after grace period.",
                  nil
                )

                acc

              entry ->
                # Sever-only, or armed-but-still-within-grace: keep tracking it.
                Map.put(acc, container.id, entry)
            end
          end)

        %{state | orphans: new_orphans, sweep_mode: mode}
    end
  end

  defp orphan_entry(container, now) do
    %{
      first_seen: now,
      detected_at: DateTime.utc_now(),
      name: container.name,
      labels: container.labels || %{}
    }
  end

  defp detected_body(container, :armed) do
    "Container #{container.name} (#{container.id}) has no deployment record; its public route was severed and it will be removed after the grace period."
  end

  defp detected_body(container, _sever_only) do
    "Container #{container.name} (#{container.id}) has no deployment record; its public route was severed. It will NOT be removed automatically (sweep mode: sever-only). Review it under Settings → Danger Zone."
  end

  defp sweep_mode do
    case Settings.get(@sweep_mode_setting, "sever_only") do
      "armed" -> :armed
      "paused" -> :paused
      _ -> :sever_only
    end
  end

  # Never reap a container that is being adopted (stamped `homelab.adopted=true`)
  # or whose `homelab.deployment_id` label points at a deployment row that still
  # exists (leased or not) — the saga owns its lifecycle and its external_id may
  # not be persisted yet. Closes the data-loss window during adoption cutover.
  defp adoption_protected?(%{labels: labels}, leased, existing_ids) do
    labels = labels || %{}

    Map.get(labels, "homelab.adopted") == "true" or
      case Integer.parse(Map.get(labels, "homelab.deployment_id", "")) do
        {id, ""} -> MapSet.member?(leased, id) or MapSet.member?(existing_ids, id)
        _ -> false
      end
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
    if SpecBuilder.declares_healthcheck?(Access.effective_health_check(deployment)) do
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
    notify_admins(title, body, severity, deployment_id)
    :ok
  end

  defp notify_admins(title, body, severity, deployment_id) do
    link = if deployment_id, do: "/deployments/#{deployment_id}", else: "/activity"

    for user <- Accounts.list_admins() do
      Notifications.create(%{
        user_id: user.id,
        title: title,
        body: body,
        severity: severity,
        link: link
      })
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
