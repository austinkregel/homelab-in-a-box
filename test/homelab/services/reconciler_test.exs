defmodule Homelab.Services.ReconcilerTest do
  use Homelab.DataCase, async: false
  use Oban.Testing, repo: Homelab.ObanRepo

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{ReleaseRunner, Releases}
  alias Homelab.Notifications.Notification
  alias Homelab.Repo
  alias Homelab.Services.Reconciler

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Insert an admin so containment alerts have a notification recipient.
    insert(:user, role: :admin)
    on_exit(fn -> Application.delete_env(:homelab, :reconciler) end)
    :ok
  end

  # Starts the reconciler with manual ticking and forces one completed pass.
  defp start_and_sync! do
    pid = start_supervised!({Reconciler, interval: :manual})
    :ok = Reconciler.sync_now()
    pid
  end

  # Sets the sweep mode via Settings and evicts it from the shared ETS cache after
  # the test so it can't leak into the next one (the cache is global, ETS is not
  # transactional).
  defp set_sweep_mode(mode) do
    {:ok, _} = Homelab.Settings.set("reconciler_sweep_mode", mode, category: "reconciler")
    on_exit(fn -> Homelab.Settings.evict("reconciler_sweep_mode") end)
  end

  defp record_orchestrator_io(test_pid) do
    Homelab.Mocks.Orchestrator
    |> stub(:publish, fn net ->
      send(test_pid, {:published, net})
      :ok
    end)
    |> stub(:unpublish, fn net ->
      send(test_pid, {:unpublished, net})
      :ok
    end)
    |> stub(:undeploy, fn id ->
      send(test_pid, {:undeployed, id})
      :ok
    end)
  end

  defp svc(id, attrs) do
    Map.merge(
      %{
        id: id,
        name: id,
        state: :running,
        health: :none,
        replicas: 1,
        image: "testapp:latest",
        labels: %{"homelab.managed" => "true"}
      },
      attrs
    )
  end

  describe "status convergence" do
    test "un-sticks :deploying -> :running when the container is healthy" do
      record_orchestrator_io(self())
      tenant = insert(:tenant, slug: "acme")
      template = insert(:app_template, slug: "blog", health_check: %{"path" => "/health"})

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :deploying,
          external_id: "c1",
          domain: "blog.acme.test"
        )

      dep_id = dep.id

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :healthy})]} end)

      Phoenix.PubSub.subscribe(Homelab.PubSub, "deployments:status")
      start_and_sync!()

      assert_receive {:deployment_status, ^dep_id, :running}, 2_000
      assert Deployments.get_deployment!(dep_id).status == :running
      # ingress invariant grants the route only once it is running
      assert_receive {:published, "homelab_acme_blog_net"}, 2_000
    end

    test "keeps :deploying (and unpublished) while a healthcheck'd container is still starting" do
      record_orchestrator_io(self())
      template = insert(:app_template, health_check: %{"path" => "/health"})

      dep =
        insert(:deployment, app_template: template, status: :deploying, external_id: "c1")

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :starting})]} end)

      start_and_sync!()

      assert Deployments.get_deployment!(dep.id).status == :deploying
      refute_received {:published, _}
    end

    test "promotes a checkless container once it has been stable" do
      Application.put_env(:homelab, :reconciler, stable_ms: 0)
      record_orchestrator_io(self())
      template = insert(:app_template, health_check: %{})

      dep =
        insert(:deployment, app_template: template, status: :deploying, external_id: "c1")

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :none})]} end)

      start_and_sync!()
      assert Deployments.get_deployment!(dep.id).status == :running
    end

    test "marks a deployment failed and alerts when its container vanishes" do
      record_orchestrator_io(self())

      dep =
        insert(:deployment, status: :running, external_id: "gone", domain: "x.acme.test")

      dep_id = dep.id

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      Phoenix.PubSub.subscribe(Homelab.PubSub, "deployments:status")
      start_and_sync!()

      assert_receive {:deployment_status, ^dep_id, :failed}, 2_000
      assert Deployments.get_deployment!(dep_id).status == :failed
      assert Repo.aggregate(Notification, :count, :id) >= 1
    end
  end

  describe "deploying timeout" do
    test "fails a deployment stuck in :deploying beyond the threshold" do
      Application.put_env(:homelab, :reconciler, deploying_timeout_ms: 0)
      record_orchestrator_io(self())
      template = insert(:app_template, health_check: %{"path" => "/health"})

      dep =
        insert(:deployment, app_template: template, status: :deploying, external_id: "c1")

      # Present but not ready, so convergence leaves it :deploying for the sweep.
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :starting})]} end)

      start_and_sync!()

      updated = Deployments.get_deployment!(dep.id)
      assert updated.status == :failed
      assert updated.error_message =~ "timed out"
    end
  end

  describe "release lease awareness and heartbeat" do
    test "stamps last_reconciled_at on each reconciled deployment" do
      record_orchestrator_io(self())
      dep = insert(:deployment, status: :running, external_id: "c1")
      assert is_nil(dep.last_reconciled_at)

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :healthy})]} end)

      start_and_sync!()

      assert Deployments.get_deployment!(dep.id).last_reconciled_at
    end

    test "does not time out a deployment owned by a live-lease release" do
      Application.put_env(:homelab, :reconciler, deploying_timeout_ms: 0)
      record_orchestrator_io(self())
      template = insert(:app_template, health_check: %{"path" => "/health"})

      dep =
        insert(:deployment, app_template: template, status: :deploying, external_id: "c1")

      {:ok, release} = Releases.plan_release(dep, [%{type: :app_container}])
      {:ok, _} = Releases.acquire_lease(release, "release-owner", 120)

      # Present but not ready: without the lease the timeout sweep would fail it.
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :starting})]} end)

      start_and_sync!()

      assert Deployments.get_deployment!(dep.id).status == :deploying
    end

    test "re-enqueues a release whose lease has expired" do
      record_orchestrator_io(self())
      dep = insert(:deployment, status: :pending)
      {:ok, release} = Releases.plan_release(dep, [%{type: :app_container}])

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      start_and_sync!()

      assert_enqueued(worker: ReleaseRunner, args: %{"release_id" => release.id})
    end
  end

  describe "ingress invariant" do
    test "publishes running ingress deployments and unpublishes non-running ones" do
      record_orchestrator_io(self())
      tenant = insert(:tenant, slug: "acme")
      running_tmpl = insert(:app_template, slug: "live", health_check: %{"path" => "/health"})
      stopped_tmpl = insert(:app_template, slug: "dead")

      insert(:deployment,
        tenant: tenant,
        app_template: running_tmpl,
        status: :running,
        external_id: "c1",
        domain: "live.acme.test"
      )

      insert(:deployment,
        tenant: tenant,
        app_template: stopped_tmpl,
        status: :stopped,
        external_id: "c2",
        domain: "dead.acme.test"
      )

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :healthy})]} end)

      start_and_sync!()

      assert_receive {:published, "homelab_acme_live_net"}, 2_000
      assert_receive {:unpublished, "homelab_acme_dead_net"}, 2_000
    end
  end

  describe "orphan sweep" do
    defp orphan_svc(id) do
      svc(id, %{
        labels: %{
          "homelab.managed" => "true",
          "homelab.tenant" => "acme",
          "homelab.app" => "ghost"
        }
      })
    end

    test "armed mode severs immediately and removes after the grace period" do
      set_sweep_mode("armed")
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan_svc("rogue1")]} end)

      # First pass: detected -> route severed + alerted.
      start_and_sync!()
      assert_receive {:unpublished, "homelab_acme_ghost_net"}, 2_000
      assert Repo.aggregate(Notification, :count, :id) >= 1

      # Second pass: grace elapsed -> removed.
      :ok = Reconciler.sync_now()
      assert_receive {:undeployed, "rogue1"}, 2_000
    end

    test "default (sever-only) severs and lists the orphan but never removes it" do
      # No mode set -> default sever_only.
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan_svc("rogue1")]} end)

      start_and_sync!()
      # Sweep several times: grace is 0, but sever-only must never undeploy.
      :ok = Reconciler.sync_now()
      :ok = Reconciler.sync_now()

      assert_receive {:unpublished, "homelab_acme_ghost_net"}, 2_000
      refute_receive {:undeployed, "rogue1"}, 300

      assert [%{id: "rogue1", tenant: "acme", app: "ghost"}] = Reconciler.list_orphans()
    end

    test "row deleted out-of-band: severed in sever-only, deleted in armed" do
      # A managed container labeled with a deployment_id whose row was deleted
      # out-of-band. In default mode it is severed but kept; armed reaps it.
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      dep = insert(:deployment, external_id: "c9")
      dep_id = dep.id
      Repo.delete!(dep)

      container =
        svc("c9", %{
          labels: %{
            "homelab.managed" => "true",
            "homelab.tenant" => "acme",
            "homelab.app" => "ghost",
            "homelab.deployment_id" => to_string(dep_id)
          }
        })

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [container]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()
      :ok = Reconciler.sync_now()
      refute_receive {:undeployed, "c9"}, 300

      # Arm it: now the orphan is genuinely reaped (grace 0 -> next pass).
      set_sweep_mode("armed")
      :ok = Reconciler.sync_now()
      assert_receive {:undeployed, "c9"}, 2_000
    end

    test "adoption cutover window: protected by an existing row even without a lease" do
      set_sweep_mode("armed")
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      # Row exists, external_id not yet persisted, no active lease.
      dep = insert(:deployment, external_id: nil)

      container =
        svc("adopting1", %{
          labels: %{
            "homelab.managed" => "true",
            "homelab.deployment_id" => to_string(dep.id)
          }
        })

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [container]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()

      # Protected by its existing deployment row, so it is never treated as an
      # orphan — no undeploy even in armed mode with zero grace.
      refute_receive {:undeployed, "adopting1"}, 300
    end

    test "arming resets the grace clock for already-tracked orphans" do
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 60_000)
      record_orchestrator_io(self())

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan_svc("rogue1")]} end)

      # Tracked in sever-only first.
      start_and_sync!()
      assert_receive {:unpublished, "homelab_acme_ghost_net"}, 2_000

      # Arm: first armed pass must not delete (grace just reset).
      set_sweep_mode("armed")
      :ok = Reconciler.sync_now()
      refute_receive {:undeployed, "rogue1"}, 300
    end

    test "paused mode does nothing" do
      set_sweep_mode("paused")
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan_svc("rogue1")]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()

      refute_receive {:unpublished, _}, 300
      refute_receive {:undeployed, "rogue1"}, 300
    end

    test "remove_orphan/1 removes a tracked orphan and rejects unknown ids" do
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan_svc("rogue1")]} end)

      start_and_sync!()
      assert [%{id: "rogue1"}] = Reconciler.list_orphans()

      assert {:error, :not_orphaned} = Reconciler.remove_orphan("nope")
      refute_receive {:undeployed, "nope"}, 300

      assert :ok = Reconciler.remove_orphan("rogue1")
      assert_receive {:undeployed, "rogue1"}, 2_000
      assert Reconciler.list_orphans() == []
    end

    test "never reaps a container labeled homelab.adopted, even past the grace period" do
      set_sweep_mode("armed")
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      adopted =
        svc("adopted1", %{
          labels: %{"homelab.managed" => "true", "homelab.adopted" => "true"}
        })

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [adopted]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()

      refute_receive {:unpublished, _}, 300
      refute_receive {:undeployed, "adopted1"}, 300
    end

    test "never reaps a container whose deployment holds an active release lease" do
      set_sweep_mode("armed")
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      dep = insert(:deployment, external_id: nil)

      {:ok, release} =
        Homelab.Deployments.Releases.plan_release(dep, [%{type: :app_container}])

      {:ok, _} = Homelab.Deployments.Releases.acquire_lease(release, "owner", 600)

      leased =
        svc("leased1", %{
          labels: %{"homelab.managed" => "true", "homelab.deployment_id" => to_string(dep.id)}
        })

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [leased]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()

      refute_receive {:undeployed, "leased1"}, 300
    end
  end

  describe "external bypass audit" do
    test "alerts once when a running deployment publishes host ports" do
      record_orchestrator_io(self())

      template =
        insert(:app_template,
          health_check: %{"path" => "/health"},
          ports: [%{"container" => 8080, "published" => true, "host_port" => 8080}]
        )

      insert(:deployment,
        app_template: template,
        status: :running,
        external_id: "c1",
        domain: "ports.acme.test"
      )

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [svc("c1", %{state: :running, health: :healthy})]} end)

      start_and_sync!()
      :ok = Reconciler.sync_now()

      bypass_alerts =
        Notification
        |> Repo.all()
        |> Enum.filter(&(&1.title == "External port bypass"))

      assert length(bypass_alerts) == 1
    end
  end

  describe "request_sync/0" do
    test "is a safe no-op when the reconciler is not running" do
      assert :ok = Reconciler.request_sync()
    end
  end
end
