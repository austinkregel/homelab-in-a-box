defmodule Homelab.Deployments.ReleaseRunnerTest do
  # async: false — the handler registry is injected via Application env, which is
  # process-global, so these must not run concurrently with other config writers.
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Deployments.{Releases, ReleaseRunner}

  # A controllable handler that reports each run/compensate to the test process
  # and can be told to fail at a given step position. Idempotency probe included
  # for the resume test.
  defmodule TestHandler do
    @behaviour Homelab.Deployments.ReleaseStep.Handler

    @impl true
    def run(step, _ctx) do
      cfg = Application.get_env(:homelab, :test_release_handler)
      send(cfg.pid, {:run, step.position, step.type})

      if step.position == cfg[:fail_at] do
        {:error, {:boom, step.position}}
      else
        {:ok, %{"ran" => step.position}}
      end
    end

    @impl true
    def compensate(step, _ctx) do
      cfg = Application.get_env(:homelab, :test_release_handler)
      send(cfg.pid, {:compensate, step.position, step.type})
      :ok
    end
  end

  setup context do
    # Route every step type through the controllable handler. RESTORE (not delete)
    # the original registry on exit, or other tests (e.g. the greenfield release
    # e2e) lose the real handlers and silently run NoopHandler.
    original_handlers = Application.fetch_env(:homelab, :release_step_handlers)
    Application.put_env(:homelab, :release_step_handlers, %{default: TestHandler})

    Application.put_env(:homelab, :test_release_handler, %{
      pid: self(),
      fail_at: context[:fail_at]
    })

    on_exit(fn ->
      case original_handlers do
        {:ok, value} -> Application.put_env(:homelab, :release_step_handlers, value)
        :error -> Application.delete_env(:homelab, :release_step_handlers)
      end

      Application.delete_env(:homelab, :test_release_handler)
    end)

    :ok
  end

  defp plan(
         deployment,
         types \\ [:network, :provision_credentials, :app_container, :publish_ingress]
       ) do
    {:ok, release} = Releases.plan_release(deployment, Enum.map(types, &%{type: &1}))
    release
  end

  describe "happy path" do
    test "runs every step in order and lands the release in :running" do
      release = plan(insert(:deployment))

      assert :ok = ReleaseRunner.run(release.id, owner: "t1")

      # Steps ran in ascending position.
      assert_received {:run, 1, :network}
      assert_received {:run, 2, :provision_credentials}
      assert_received {:run, 3, :app_container}
      assert_received {:run, 4, :publish_ingress}

      release = Releases.get_release(release.id)
      assert release.status == :running
      assert Enum.all?(release.steps, &(&1.status == :completed))

      # Each completed step recorded its handle.
      handles = Map.new(release.steps, &{&1.position, &1.resource_handle["ran"]})
      assert handles == %{1 => 1, 2 => 2, 3 => 3, 4 => 4}
    end
  end

  describe "failure and compensation" do
    @tag fail_at: 3
    test "rolls back completed steps in reverse order and stops" do
      release = plan(insert(:deployment))

      assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t1")

      # Steps 1..3 attempted; 4 never reached.
      assert_received {:run, 1, _}
      assert_received {:run, 2, _}
      assert_received {:run, 3, _}
      refute_received {:run, 4, _}

      # Compensation walks completed steps (1,2) in DESCENDING order. The failed
      # step (3) is not compensated.
      assert_received {:compensate, 2, _}
      assert_received {:compensate, 1, _}
      refute_received {:compensate, 3, _}

      release = Releases.get_release(release.id)
      assert release.status == :rolled_back

      by_pos = Map.new(release.steps, &{&1.position, &1.status})
      assert by_pos[1] == :compensated
      assert by_pos[2] == :compensated
      assert by_pos[3] == :failed
      assert by_pos[4] == :pending
    end

    @tag fail_at: 2
    test "notifies admins with a deployment link on rollback" do
      admin = insert(:user, role: :admin)
      release = plan(insert(:deployment))

      assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t1")

      notifications = Homelab.Notifications.list_recent(admin.id, 10)
      assert Enum.any?(notifications, &(&1.title == "Release rolled back"))
      assert Enum.any?(notifications, &(&1.link == "/deployments/#{release.deployment_id}"))
    end
  end

  describe "crash resume" do
    test "reclaims a stuck :running step and does not re-run completed steps" do
      release = plan(insert(:deployment))
      [s1, s2, s3, _s4] = Enum.sort_by(release.steps, & &1.position)

      # Simulate a crash mid-release: 1,2 completed; 3 left :running.
      {:ok, _} = Releases.transition_step(s1, :completed, [:pending])
      {:ok, _} = Releases.transition_step(s2, :completed, [:pending])
      {:ok, _} = Releases.transition_step(s3, :running, [:pending])

      assert :ok = ReleaseRunner.run(release.id, owner: "t2")

      # Already-completed steps must NOT re-run.
      refute_received {:run, 1, _}
      refute_received {:run, 2, _}
      # The reclaimed step and the remaining one DO run.
      assert_received {:run, 3, _}
      assert_received {:run, 4, _}

      release = Releases.get_release(release.id)
      assert release.status == :running
      assert Enum.all?(release.steps, &(&1.status == :completed))
    end

    # `:rolling_back` is ACTIVE, not terminal, so the reconciler re-enqueues it and
    # `run/1`'s terminal guard lets it through — and `drive/2` sent it to `loop/2`, which
    # only asks for the next `:pending` step. A release interrupted mid-compensation was
    # therefore driven FORWARD: it wrote the Domain row, published A records to the
    # external DNS provider and attached ingress, all while rolling back.
    #
    # And it could never finish: `finalize/1`'s CAS excludes `:rolling_back`, so the
    # release sat active forever and `releases_one_active_per_deployment` blocked that
    # deployment from ever getting another release.
    test "a release interrupted mid-rollback compensates instead of running on" do
      deployment = insert(:deployment)
      release = plan(deployment)
      [s1, s2, _s3, _s4] = Enum.sort_by(release.steps, & &1.position)

      # Mid-compensation when the node died: 1 completed, 2 mid-compensate, 3 and 4
      # never reached.
      {:ok, _} = Releases.transition_step(s1, :completed, [:pending])
      {:ok, _} = Releases.transition_step(s2, :completed, [:pending])
      {:ok, _} = Releases.transition_step(s2, :compensating, [:completed])
      {:ok, _} = Releases.transition_release(release, :provisioning, [:planning])

      {:ok, release} =
        Releases.transition_release(Releases.get_release(release.id), :rolling_back, [
          :provisioning
        ])

      assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t-rb")

      # Nothing was driven forward. `:publish_ingress` here stands in for the real
      # blast radius: on the routed plan this position is a DNS record published to an
      # external, resolver-cached provider.
      refute_received {:run, 3, _}
      refute_received {:run, 4, _}

      # The interrupted step is re-compensated — `compensate/2` is contractually
      # idempotent — and the walk continues down.
      assert_received {:compensate, 2, _}
      assert_received {:compensate, 1, _}

      release = Releases.get_release(release.id)
      assert release.status == :rolled_back
    end

    # The other half: a rollback that finds nothing to compensate must still settle. It
    # used to run every remaining step, no-op `finalize/1`'s CAS, and return `:ok` with
    # the release still `:rolling_back` — permanently active, permanently blocking the
    # deployment's next release.
    test "a rollback with nothing to compensate still reaches a terminal status" do
      deployment = insert(:deployment)
      release = plan(deployment)

      {:ok, _} = Releases.transition_release(release, :provisioning, [:planning])

      {:ok, release} =
        Releases.transition_release(Releases.get_release(release.id), :rolling_back, [
          :provisioning
        ])

      assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t-rb2")

      refute_received {:run, _, _}
      assert Releases.get_release(release.id).status == :rolled_back

      # Terminal for real: the deployment can be given another release.
      refute Releases.get_active_release(deployment.id)
    end
  end

  # THE GitLab adoption bug. The lease was refreshed only BETWEEN steps, so a step
  # that outran the TTL (a backup copying tens of GB) let it lapse mid-flight. The
  # reconciler re-enqueues every release whose lease has expired, the second runner
  # reclaimed the still-`:running` step and re-ran it concurrently, and its
  # `File.rm_rf!` of the deterministic backup dest deleted the tree the first runner
  # was still checksumming — surfacing as "could not stream .../data/...: no such
  # file or directory" and rolling the whole adoption back.
  describe "lease heartbeat (a step longer than the TTL)" do
    defmodule BlockingHandler do
      @behaviour Homelab.Deployments.ReleaseStep.Handler

      @impl true
      def run(_step, _ctx) do
        cfg = Application.get_env(:homelab, :test_release_handler)
        send(cfg.pid, {:blocking_started, self()})

        receive do
          :proceed -> {:ok, %{"ran" => true}}
        after
          5_000 -> {:error, :test_timeout}
        end
      end

      @impl true
      def compensate(_step, _ctx), do: :ok
    end

    setup do
      Application.put_env(:homelab, :release_step_handlers, %{default: BlockingHandler})
      # A 1s lease renewed every 100ms: the step below stays blocked well past the
      # point the old code would have dropped it.
      Application.put_env(:homelab, :release_lease_ttl_seconds, 1)
      Application.put_env(:homelab, :release_lease_heartbeat_ms, 100)

      on_exit(fn ->
        Application.delete_env(:homelab, :release_lease_ttl_seconds)
        Application.delete_env(:homelab, :release_lease_heartbeat_ms)
      end)

      :ok
    end

    test "the release never becomes resumable while its step is still running" do
      release = plan(insert(:deployment), [:backup_verify])
      task = Task.async(fn -> ReleaseRunner.run(release.id, owner: "hb-owner") end)

      assert_receive {:blocking_started, handler}, 1_000

      # Sit here past the 1s TTL. Without the heartbeat the lease lapses and the
      # reconciler's resumable query picks the release up — which is what let a
      # second runner start on top of the first.
      Process.sleep(1_500)

      resumable = Enum.map(Releases.list_resumable_releases(), & &1.id)
      refute release.id in resumable, "a running step must keep its lease alive"

      send(handler, :proceed)
      assert :ok = Task.await(task, 5_000)
      assert Releases.get_release(release.id).status == :running
    end

    test "losing the lease mid-step does not take the step down with it" do
      release = plan(insert(:deployment), [:backup_verify])
      task = Task.async(fn -> ReleaseRunner.run(release.id, owner: "hb-owner") end)

      assert_receive {:blocking_started, handler}, 1_000

      # Someone else takes ownership out from under the running step. The heartbeat
      # must NOT resurrect it (two runners both believing they own the release is
      # the exact state the lease exists to prevent) — it gives up and logs.
      {1, _} =
        Homelab.Deployments.Release
        |> where([r], r.id == ^release.id)
        |> Homelab.Repo.update_all(set: [lease_owner: "thief"])

      assert Releases.renew_lease(release.id, "hb-owner", 1) == :lost

      # The step itself is already running and cannot be un-run, so it finishes
      # normally; the compare-and-set transitions are what keep the loser honest.
      send(handler, :proceed)
      assert :ok = Task.await(task, 5_000)
    end
  end

  describe "lease heartbeat (a compensation walk longer than the TTL)" do
    # The forward path renews the lease while a handler runs. Compensation did not: the
    # lease was acquired once at the top of `rollback/3` and the whole descending walk
    # ran under it. A rollback undeploying several containers — each a stop with the
    # daemon's timeout, a force-rm and a network prune — outlives the TTL, and
    # `list_resumable_releases/0` then hands the release to a SECOND runner while the
    # first is still compensating.
    defmodule SlowCompensator do
      @behaviour Homelab.Deployments.ReleaseStep.Handler

      @impl true
      def run(step, _ctx) do
        cfg = Application.get_env(:homelab, :test_release_handler)

        if step.position == cfg[:fail_at],
          do: {:error, {:boom, step.position}},
          else: {:ok, %{"ran" => step.position}}
      end

      @impl true
      def compensate(step, _ctx) do
        cfg = Application.get_env(:homelab, :test_release_handler)

        # The FIRST step compensated (the walk is descending) sits past the TTL. The
        # next one then reports whether a rival runner could have taken the release
        # out from under it — which is the actual damage, not the elapsed time.
        # Comfortably past the 1s TTL. `lease_expires_at` is `:utc_datetime`, so both
        # sides of the comparison are truncated to whole seconds and a margin under
        # ~1s makes the answer depend on where in the second the walk started.
        if step.position == cfg[:slow_at] do
          Process.sleep(2_500)
        else
          send(
            cfg.pid,
            {:rival, step.position, Releases.acquire_lease(cfg.release, "rival-runner", 120)}
          )
        end

        :ok
      end
    end

    setup do
      Application.put_env(:homelab, :release_step_handlers, %{default: SlowCompensator})
      Application.put_env(:homelab, :release_lease_ttl_seconds, 1)
      Application.put_env(:homelab, :release_lease_heartbeat_ms, 100)

      on_exit(fn ->
        Application.delete_env(:homelab, :release_lease_ttl_seconds)
        Application.delete_env(:homelab, :release_lease_heartbeat_ms)
      end)

      :ok
    end

    test "the lease is held for the whole walk, not just its first step" do
      release = plan(insert(:deployment), [:network, :app_container, :publish_ingress])

      Application.put_env(:homelab, :test_release_handler, %{
        pid: self(),
        fail_at: 3,
        slow_at: 2,
        release: release
      })

      assert {:cancel, _} = ReleaseRunner.run(release.id, owner: "rb-owner")

      # Step 2 compensated slowly; step 1 then asked whether anyone else could have
      # grabbed the release mid-walk. Without a heartbeat the 1s lease has lapsed and
      # the answer is yes.
      assert_received {:rival, 1, result}

      assert result == :taken,
             "a second runner acquired the lease mid-compensation: #{inspect(result)}"
    end
  end

  describe "lease contention" do
    test "snoozes when another owner holds an unexpired lease" do
      release = plan(insert(:deployment))
      {:ok, _} = Releases.acquire_lease(release, "other-owner", 120)

      assert {:snooze, secs} = ReleaseRunner.run(release.id, owner: "t3")
      assert is_integer(secs) and secs > 0

      # No work happened.
      refute_received {:run, _, _}
      assert Releases.get_release(release.id).status == :planning
    end
  end

  describe "enqueue_or_log/1" do
    # The one case this function exists for is the one it did not handle.
    #
    # Its docstring names "the job queue was briefly unreachable", and it matched only
    # `{:error, reason}`. `Oban.insert/1` returns that shape for a CHANGESET failure; a
    # BACKEND failure raises out of `Engine.insert_job` -> `Repo.transaction`. So the
    # raise propagated to a caller holding an already-committed `:planning` release —
    # `deploy_release/2`, `create_and_deploy_release/2`, `redeploy_netns_stack/1` and
    # `Adoption.apply_service/3` — and each reported a failed deploy for a release that
    # is in fact fine and that the reconciler will resume.
    #
    # Broken at the backend rather than by stubbing `enqueue/1`: the point is that
    # `Oban.insert/1` RAISES, and a test that asserted anything else would pass over a
    # function that still only matched `{:error, _}`. The DDL runs inside the sandbox
    # transaction, so it is undone with everything else.
    test "survives a backend failure, which raises rather than returning an error" do
      release = plan(insert(:deployment))

      Homelab.ObanRepo.query!("ALTER TABLE oban_jobs RENAME TO oban_jobs_unreachable")

      assert :ok = ReleaseRunner.enqueue_or_log(release)
    end
  end

  describe "terminal releases" do
    test "are a no-op (idempotent re-delivery)" do
      release = plan(insert(:deployment))
      {:ok, _} = Releases.transition_release(release, :provisioning, [:planning])

      {:ok, _} =
        Releases.transition_release(Releases.get_release(release.id), :running, [:provisioning])

      assert :ok = ReleaseRunner.run(release.id, owner: "t4")
      refute_received {:run, _, _}
    end
  end
end
