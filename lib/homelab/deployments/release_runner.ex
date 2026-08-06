defmodule Homelab.Deployments.ReleaseRunner do
  @moduledoc """
  The saga executor for deployment releases — the durable engine that was missing
  alongside the `Release`/`ReleaseStep` data model.

  An Oban job (queue `:releases`) drives one release. Under a held lease it runs
  pending steps in ascending `position`, dispatching each to a registered
  `Homelab.Deployments.ReleaseStep.Handler`. On a step failure it flips the
  release to `:rolling_back` and walks the completed steps in **descending**
  position, compensating each, then settles at `:rolled_back` (or
  `:rollback_failed`).

  Durability / crash-resume:

    * The lease (`Releases.acquire_lease/3`) makes a release single-writer. A
      second job for the same release that cannot take the lease `:snooze`s
      rather than double-driving. It is held for the whole time a step runs, not
      just between steps — a step is not interruptible and can run far longer
      than the TTL, so a HEARTBEAT renews it while the handler works (see
      `with_lease_heartbeat/3`).
    * On resume the runner first reclaims any step left `:running` by a crashed
      node back to `:pending` so it re-runs from scratch — which is safe because
      handlers are required to be idempotent.
    * All step/release transitions are compare-and-set, so a duplicate or raced
      runner no-ops instead of corrupting state.

  Handler registry: `config :homelab, :release_step_handlers, %{type => module}`.
  Unregistered types fall back to `:default`, then to
  `Homelab.Deployments.ReleaseSteps.NoopHandler`, so the engine is fully testable
  before the real Docker step handlers exist.
  """

  use Oban.Worker, queue: :releases, max_attempts: 5

  require Logger

  alias Homelab.Repo
  alias Homelab.Deployments.{Release, Releases, ReleaseSteps}
  alias Homelab.Services.ActivityLog

  # Step types that bring a workload into existence. Their completion is the saga's
  # equivalent of `do_deploy/1`'s one "<app> deployed" entry, and the only per-step
  # success worth an Activity row — logging every step would bury the transitions that
  # matter under health polls and grant reconciliations.
  @workload_steps [
    :dependency_container,
    :app_container,
    :netns_child_container,
    :adopt_container
  ]

  @lease_ttl_seconds 120
  @snooze_seconds 15
  # A third of the TTL, so two beats can be lost to a slow database before the
  # lease is even at risk. Overridable for tests, which cannot wait 40 seconds.
  @lease_heartbeat_ms 40_000

  # --- Oban entry point -----------------------------------------------------

  @impl Oban.Worker
  def perform(%Oban.Job{args: %{"release_id" => release_id}, id: job_id}) do
    run(release_id, owner: "oban-job-#{job_id}")
  end

  @doc "Enqueues a release for execution on the `:releases` queue."
  def enqueue(%Release{id: release_id}) do
    %{"release_id" => release_id} |> new() |> Oban.insert()
  end

  @doc """
  Enqueues a release, downgrading a failed enqueue to a log line. Always `:ok`.

  This is the shape every planner wants, and `{:ok, _job} = enqueue(release)` is the
  shape none of them do. Oban runs on `Homelab.ObanRepo`, a physically separate
  Postgres, so the enqueue can never join the transaction that committed the release —
  by the time it runs, the release row EXISTS. Raising there converts "the job queue
  was briefly unreachable" into a caller who believes the whole deploy failed, while a
  perfectly good `:planning` release sits committed.

  Nothing is lost by not raising: `Reconciler.resume_stuck_releases/0` re-enqueues
  every release with no live lease on its next tick, so the un-enqueued release is
  picked up automatically. The worst case is a delay.
  """
  def enqueue_or_log(%Release{} = release) do
    case enqueue(release) do
      {:ok, _job} ->
        :ok

      {:error, reason} ->
        Logger.error(
          "[release] #{release.id} planned but not enqueued (#{inspect(reason)}); " <>
            "the reconciler will resume it"
        )

        :ok
    end
  end

  # --- Engine (directly callable, used by Oban and by tests) ----------------

  @doc """
  Drives `release_id` to a terminal state under a lease owned by `:owner`
  (defaults to a node-scoped id). Returns `:ok` on success, `{:snooze, secs}` if
  another owner holds the lease, `{:cancel, reason}` once a failed release has
  been fully rolled back (no Oban retry), or `{:error, reason}` if compensation
  itself failed (Oban retries).
  """
  def run(release_id, opts \\ []) do
    owner = Keyword.get_lazy(opts, :owner, &default_owner/0)

    case Releases.get_release(release_id) do
      nil ->
        {:cancel, :release_not_found}

      %Release{} = release ->
        if Release.terminal?(release) do
          :ok
        else
          case Releases.acquire_lease(release, owner, lease_ttl_seconds()) do
            {:ok, release} -> drive(release, owner)
            :taken -> {:snooze, @snooze_seconds}
          end
        end
    end
  end

  # --- Forward progress -----------------------------------------------------

  # A release resumed while it was already ROLLING BACK. `:rolling_back` is active,
  # not terminal, so the reconciler re-enqueues it and `run/1`'s guard lets it through
  # — and every non-terminal release used to land in `loop/2`, which only asks for the
  # next `:pending` step. So an interrupted rollback was driven FORWARD: it wrote the
  # Domain row, published A records to an external, resolver-cached DNS provider, and
  # attached ingress, all as part of undoing itself. It could not finish either, since
  # `finalize/1`'s CAS excludes `:rolling_back` — the release stayed active forever and
  # `releases_one_active_per_deployment` blocked the deployment's next release.
  #
  # The direction of travel is a property of the release, so it is decided here rather
  # than inside the loop. The original failure reason is on the row.
  defp drive(%Release{status: :rolling_back} = release, owner) do
    reclaim_running_steps(release)

    Logger.warning("[release] #{release.id} resumed while rolling back; continuing compensation")

    compensate_and_settle(release.id, owner, release.error_message || :interrupted_rollback)
  end

  defp drive(release, owner) do
    reclaim_running_steps(release)
    # planning -> provisioning; no-ops cleanly on resume (already provisioning).
    case Releases.transition_release(release, :provisioning, [:planning]) do
      {:ok, _} ->
        activity(
          :info,
          "deploy",
          "#{release_label(release)} release started",
          release.deployment_id
        )

      {:noop, _} ->
        :ok
    end

    loop(release.id, owner)
  end

  defp loop(release_id, owner) do
    release = Releases.get_release(release_id)

    case Releases.next_pending_step(release) do
      nil ->
        finalize(release)

      step ->
        # Refresh the lease before each step so long plans don't lose ownership.
        case Releases.acquire_lease(release, owner, lease_ttl_seconds()) do
          :taken ->
            {:snooze, @snooze_seconds}

          {:ok, _release} ->
            case run_step(step, build_ctx(release), release_id, owner) do
              :ok -> loop(release_id, owner)
              {:error, reason} -> rollback(release_id, owner, reason)
            end
        end
    end
  end

  defp finalize(release) do
    case Releases.transition_release(release, :running, [:provisioning, :planning]) do
      {:ok, _} ->
        activity(:info, "deploy", "#{release_label(release)} deployed", release.deployment_id)

      {:noop, _} ->
        :ok
    end

    :ok
  end

  defp run_step(step, ctx, release_id, owner) do
    case Releases.transition_step(step, :running, [:pending]) do
      # Another writer already advanced this step; let the loop re-read.
      {:noop, _step} ->
        :ok

      {:ok, step} ->
        handler = handler_for(step.type)

        try do
          case with_lease_heartbeat(release_id, owner, fn -> handler.run(step, ctx) end) do
            {:ok, handle} when is_map(handle) ->
              # Activity entries hang off the compare-and-set, never off the handler
              # call. The CAS is already the idempotency guard the saga relies on, so a
              # resumed or raced runner that re-runs an idempotent handler gets
              # `{:noop, _}` here and writes no second entry. Logging next to the
              # handler instead would double every line on every resume.
              case Releases.transition_step(step, :completed, [:running], handle: handle) do
                {:ok, completed} -> log_step_completed(completed, ctx)
                {:noop, _} -> :ok
              end

              :ok

            {:error, reason} ->
              case Releases.transition_step(step, :failed, [:running],
                     error: format_error(reason)
                   ) do
                {:ok, failed} -> log_step_failed(failed, ctx, reason)
                {:noop, _} -> :ok
              end

              {:error, reason}
          end
        rescue
          e ->
            case Releases.transition_step(step, :failed, [:running], error: Exception.message(e)) do
              {:ok, failed} -> log_step_failed(failed, ctx, e)
              {:noop, _} -> :ok
            end

            {:error, e}
        end
    end
  end

  # --- Lease heartbeat ------------------------------------------------------

  # Holds the lease for as long as `fun` runs.
  #
  # The lease used to be refreshed only BETWEEN steps, which silently assumed
  # every step finishes inside the 120s TTL. A backup of GitLab's data dir copies
  # tens of GB and does not, and the consequence was not a stalled release — it was
  # a CORRUPTED one:
  #
  #   1. the lease lapses mid-copy;
  #   2. the reconciler re-enqueues every release whose lease has expired, so a
  #      second Oban job starts (the queue runs 4 at a time, so immediately);
  #   3. it acquires the now-free lease, reclaims the still-`:running` step back to
  #      `:pending`, and runs the SAME step again, concurrently;
  #   4. `FileCopy` begins with `File.rm_rf!` of a dest path derived only from the
  #      release and target — the same path the first runner is still hashing.
  #
  # Which surfaced as the first runner failing on a file it had just written:
  # `could not stream ".../data/reconfigure/1748005528.log": no such file or
  # directory`, rolling the whole adoption back. Renewing while the step runs is
  # what makes a long step safe; nothing downstream had to become concurrency-proof.
  #
  # A lost lease is NOT escalated here. The step is already running and cannot be
  # un-run, and the transitions that follow it are compare-and-set, so the loser
  # no-ops rather than corrupting state. Logging it keeps the cause visible.
  defp with_lease_heartbeat(release_id, owner, fun) do
    {pid, ref} = spawn_monitor(fn -> heartbeat_loop(release_id, owner) end)

    try do
      fun.()
    after
      Process.demonitor(ref, [:flush])
      Process.exit(pid, :kill)
    end
  end

  defp heartbeat_loop(release_id, owner) do
    Process.sleep(heartbeat_ms())

    case Releases.renew_lease(release_id, owner, lease_ttl_seconds()) do
      :ok ->
        heartbeat_loop(release_id, owner)

      :lost ->
        Logger.warning(
          "[release] #{release_id} lost its lease while a step was running (owner #{owner})"
        )
    end
  end

  defp heartbeat_ms do
    Application.get_env(:homelab, :release_lease_heartbeat_ms, @lease_heartbeat_ms)
  end

  # Overridable so a test can prove the renewal outlives the TTL without sitting
  # there for two minutes.
  defp lease_ttl_seconds do
    Application.get_env(:homelab, :release_lease_ttl_seconds, @lease_ttl_seconds)
  end

  # --- Rollback / compensation ----------------------------------------------

  defp rollback(release_id, owner, reason) do
    Logger.warning("[release] #{release_id} failed (#{format_error(reason)}); rolling back")

    release = Releases.get_release(release_id)
    _ = Releases.acquire_lease(release, owner, lease_ttl_seconds())

    case Releases.transition_release(release, :rolling_back, [:planning, :provisioning],
           error: format_error(reason)
         ) do
      {:ok, _} ->
        activity(
          :error,
          "deploy",
          "#{release_label(release)} release failed, rolling back: #{format_error(reason)}",
          release.deployment_id
        )

      {:noop, _} ->
        :ok
    end

    compensate_and_settle(release_id, owner, reason)
  end

  # The compensation walk and the settle after it, shared by a fresh rollback and by one
  # resumed mid-flight (`drive/2`). Assumes the release is already `:rolling_back`.
  defp compensate_and_settle(release_id, owner, reason) do
    release = Releases.get_release(release_id)
    _ = Releases.acquire_lease(release, owner, lease_ttl_seconds())
    ctx = build_ctx(release)

    case compensate_all(Releases.completed_steps_desc(release), ctx) do
      :ok ->
        release = Releases.get_release(release_id)

        case Releases.transition_release(release, :rolled_back, [:rolling_back]) do
          {:ok, _} ->
            activity(
              :error,
              "deploy",
              "#{release_label(release)} release rolled back",
              release.deployment_id
            )

          {:noop, _} ->
            :ok
        end

        notify_admins_rollback(
          ctx.deployment,
          "Release rolled back",
          "The release for #{deployment_label(ctx.deployment)} failed and was rolled back: #{format_error(reason)}"
        )

        {:cancel, {:rolled_back, format_error(reason)}}

      {:error, comp_reason} ->
        Logger.error("[release] #{release_id} rollback FAILED: #{format_error(comp_reason)}")
        release = Releases.get_release(release_id)

        case Releases.transition_release(release, :rollback_failed, [:rolling_back],
               error: format_error(comp_reason)
             ) do
          {:ok, _} ->
            activity(
              :error,
              "deploy",
              "#{release_label(release)} rollback FAILED: #{format_error(comp_reason)}",
              release.deployment_id
            )

          {:noop, _} ->
            :ok
        end

        notify_admins_rollback(
          ctx.deployment,
          "Release rollback FAILED",
          "The release for #{deployment_label(ctx.deployment)} failed AND its rollback failed — manual intervention needed: #{format_error(comp_reason)}"
        )

        {:error, {:rollback_failed, comp_reason}}
    end
  end

  # Surfaces a stuck/rolled-back release to admins via the notification bell.
  defp notify_admins_rollback(deployment, title, body) do
    link = deployment && "/deployments/#{deployment.id}"

    for admin <- Homelab.Accounts.list_admins() do
      Homelab.Notifications.create(%{
        user_id: admin.id,
        title: title,
        body: body,
        severity: "error",
        link: link
      })
    end

    :ok
  rescue
    _ -> :ok
  end

  defp deployment_label(nil), do: "a deployment"

  defp deployment_label(%{app_template: %{name: name}}) when is_binary(name), do: name
  defp deployment_label(%{id: id}), do: "deployment ##{id}"

  # --- Activity log ---------------------------------------------------------
  #
  # The saga wrote nothing to the Activity page. `do_deploy/1` logged an info on a
  # successful deploy and an error on either failure, so every deployment made through
  # the imperative path had a history and every deployment made through a release had
  # none — greenfield, adoption, netns and redeploy alike.
  #
  # This lives in the runner rather than in the handlers for two reasons: the entries
  # are release TRANSITIONS, not resources (nothing about a log line is compensatable,
  # and a step per entry would double every plan), and the runner is the one place that
  # sees every saga path, so nothing has to be remembered when a new planner is added.

  # Which deployment an entry files under. A step names its own target in
  # `resource_handle["deployment_id"]` — so a companion's failure files under the
  # COMPANION, which is what the Activity page filters on; a release-level entry files
  # under the release's app.
  defp step_deployment_id(step, ctx) do
    Map.get(step.resource_handle || %{}, "deployment_id") ||
      (ctx.release && ctx.release.deployment_id) ||
      (ctx.deployment && ctx.deployment.id)
  end

  defp log_step_completed(%{type: type} = step, ctx) when type in @workload_steps do
    id = step_deployment_id(step, ctx)
    activity(:info, "deploy", "#{label_for(id)} deployed", id)
  end

  defp log_step_completed(_step, _ctx), do: :ok

  defp log_step_failed(step, ctx, reason) do
    id = step_deployment_id(step, ctx)

    activity(
      :error,
      "deploy",
      "#{label_for(id)} #{step.type} failed: #{format_error(reason)}",
      id
    )
  end

  defp release_label(release), do: label_for(release && release.deployment_id)

  defp label_for(nil), do: deployment_label(nil)

  defp label_for(deployment_id) do
    case Homelab.Deployments.get_deployment(deployment_id) do
      {:ok, deployment} -> deployment_label(deployment)
      _ -> deployment_label(%{id: deployment_id})
    end
  end

  # Best-effort, always. An Activity write must never be the thing that fails a
  # release or a rollback.
  defp activity(level, source, message, deployment_id) do
    metadata = if deployment_id, do: %{deployment_id: deployment_id}, else: %{}
    apply(ActivityLog, level, [source, message, metadata])
    :ok
  rescue
    _ -> :ok
  end

  defp compensate_all(steps, ctx) do
    Enum.reduce_while(steps, :ok, fn step, _acc ->
      case compensate_step(step, ctx) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp compensate_step(step, ctx) do
    case Releases.transition_step(step, :compensating, [:completed]) do
      {:noop, _step} ->
        :ok

      {:ok, step} ->
        handler = handler_for(step.type)

        try do
          case apply_compensate(handler, step, ctx) do
            :ok ->
              Releases.transition_step(step, :compensated, [:compensating])
              :ok

            {:error, reason} ->
              Releases.transition_step(step, :failed, [:compensating],
                error: format_error(reason)
              )

              {:error, reason}
          end
        rescue
          e ->
            Releases.transition_step(step, :failed, [:compensating], error: Exception.message(e))
            {:error, e}
        end
    end
  end

  defp apply_compensate(handler, step, ctx) do
    if function_exported?(handler, :compensate, 2) do
      handler.compensate(step, ctx)
    else
      :ok
    end
  end

  # --- Helpers --------------------------------------------------------------

  # A step left mid-flight by a crashed node is put back where the walk that owns it
  # will pick it up again. Idempotent handlers — required of every handler — make both
  # re-runs safe.
  #
  #   * `:running` -> `:pending`, so the forward loop re-runs it.
  #   * `:compensating` -> `:completed`, so the compensation walk re-compensates it.
  #     `completed_steps_desc/1` is what that walk selects on, so a step abandoned
  #     mid-compensation was invisible to it and its side effect stayed live for good
  #     — an attached ingress, a published A record — while the release still settled
  #     `:rolled_back` and reported the world clean.
  defp reclaim_running_steps(release) do
    release = Repo.preload(release, :steps)

    for step <- release.steps do
      case step.status do
        :running -> Releases.transition_step(step, :pending, [:running])
        :compensating -> Releases.transition_step(step, :completed, [:compensating])
        _ -> :ok
      end
    end

    :ok
  end

  defp build_ctx(release) do
    release = Repo.preload(release, :deployment)
    %{release: release, deployment: release.deployment}
  end

  defp handler_for(type) do
    registry = Application.get_env(:homelab, :release_step_handlers, %{})

    Map.get(registry, type) || Map.get(registry, :default) || ReleaseSteps.NoopHandler
  end

  defp default_owner, do: "release-runner:#{node()}"

  defp format_error(reason) when is_binary(reason), do: reason
  defp format_error(reason), do: inspect(reason)
end
