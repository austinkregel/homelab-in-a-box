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
