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

  # publish/unpublish take the WORKLOAD's id now, not a network name: they attach and
  # detach the container from the shared ingress network, which is what actually decides
  # whether Traefik can route to it. They used to connect Traefik to
  # `homelab_<tenant>_<app>_net`, a network nothing was ever on — so every "route
  # severed" alert in this file was reporting something that did not happen.
  defp record_orchestrator_io(test_pid) do
    Homelab.Mocks.Orchestrator
    |> stub(:publish, fn container_id, _network ->
      send(test_pid, {:published, container_id})
      :ok
    end)
    |> stub(:unpublish, fn container_id, _network ->
      send(test_pid, {:unpublished, container_id})
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
      assert_receive {:published, "c1"}, 2_000
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

  describe "stranded pending deployments" do
    # `converge_one/2` returns on `external_id: nil`, and every other sweep is about
    # workloads that exist — so a `:pending` row that no release ever covered is invisible
    # to all of them. It reads on the page as "waiting on a deploy" forever, with an empty
    # Releases tab because there is genuinely nothing to show, and no amount of waiting
    # changes it.
    defp backdate!(deployment, seconds) do
      at =
        NaiveDateTime.utc_now()
        |> NaiveDateTime.add(seconds, :second)
        |> NaiveDateTime.truncate(:second)

      deployment |> Ecto.Changeset.change(updated_at: at) |> Repo.update!()
    end

    defp no_services do
      stub(Homelab.Mocks.Orchestrator, :list_services, fn -> {:ok, []} end)
    end

    test "plans a release for a pending deployment nothing is driving" do
      no_services()
      dep = insert(:deployment, status: :pending, external_id: nil)
      backdate!(dep, -600)

      refute Releases.driving_release(dep.id)

      start_and_sync!()

      release = Releases.driving_release(dep.id)
      assert release, "the stranded deployment should have been given a release"
      assert release.deployment_id == dep.id
    end

    # The guard that stops this becoming a redeploy loop. A release that failed is a
    # decision for the operator to look at and re-run deliberately; re-planning it every
    # 20s would hammer a deploy that cannot succeed.
    test "leaves a deployment whose release already failed alone" do
      no_services()
      dep = insert(:deployment, status: :pending, external_id: nil)
      backdate!(dep, -600)

      {:ok, release} = Releases.plan_release(dep, [%{type: :app_container}])
      {:ok, _} = Releases.transition_release(release, :failed, [:planning])

      start_and_sync!()

      assert Releases.driving_release(dep.id).id == release.id
      assert Repo.aggregate(Homelab.Deployments.Release, :count) == 1
    end

    # Every planner creates rows and THEN plans, so a healthy deploy passes through
    # exactly this shape for a moment. Adopting it there would plan a second release for
    # a deployment that is already about to get one.
    test "leaves a freshly created deployment inside the grace window alone" do
      no_services()
      dep = insert(:deployment, status: :pending, external_id: nil)

      start_and_sync!()

      refute Releases.driving_release(dep.id)
    end

    test "skips a deployment an in-flight release already holds the lease on" do
      no_services()
      dep = insert(:deployment, status: :pending, external_id: nil)
      backdate!(dep, -600)

      {:ok, release} = Releases.plan_release(dep, [%{type: :app_container}])
      {:ok, _} = Releases.acquire_lease(release, "someone-else", 120)

      start_and_sync!()

      assert Repo.aggregate(Homelab.Deployments.Release, :count) == 1
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

      assert_receive {:published, "c1"}, 2_000
      assert_receive {:unpublished, "c2"}, 2_000
    end

    # A gluetun donor holds no name of its own — every domain in the stack belongs to a
    # child — so a `domain`-keyed query cannot see it and nothing else re-attaches it.
    defp netns_stack do
      tenant = insert(:tenant, slug: "acme")

      donor =
        insert(:deployment,
          tenant: tenant,
          app_template: insert(:app_template, slug: "gluetun", ports: []),
          domain: nil,
          status: :running,
          external_id: "vpn1"
        )

      {tenant, donor}
    end

    defp routed_child(tenant, donor) do
      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, slug: "sonarr", exposure_mode: :public),
        domain: "sonarr.acme.test",
        network_parent_id: donor.id,
        status: :running,
        external_id: "sonarr1"
      )
    end

    test "attaches a domainless donor whose children carry the routes" do
      record_orchestrator_io(self())
      {tenant, donor} = netns_stack()
      routed_child(tenant, donor)

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn ->
        {:ok,
         [
           svc("vpn1", %{state: :running, health: :healthy}),
           svc("sonarr1", %{state: :running, health: :healthy})
         ]}
      end)

      start_and_sync!()

      assert_receive {:published, "vpn1"}, 2_000
      refute_receive {:unpublished, "vpn1"}, 300
    end

    test "keeps a donor attached while it is unhealthy" do
      record_orchestrator_io(self())
      {tenant, donor} = netns_stack()
      routed_child(tenant, donor)

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn ->
        {:ok,
         [
           svc("vpn1", %{state: :running, health: :unhealthy}),
           svc("sonarr1", %{state: :running, health: :healthy})
         ]}
      end)

      start_and_sync!()

      assert Deployments.get_deployment!(donor.id).status == :deploying
      assert_receive {:published, "vpn1"}, 2_000
      refute_receive {:unpublished, "vpn1"}, 300
    end

    test "leaves a donor with no routed children off the ingress network" do
      record_orchestrator_io(self())
      {tenant, donor} = netns_stack()

      insert(:deployment,
        tenant: tenant,
        app_template: insert(:app_template, slug: "qbit", exposure_mode: :service),
        domain: nil,
        network_parent_id: donor.id,
        status: :running,
        external_id: "qbit1"
      )

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn ->
        {:ok,
         [
           svc("vpn1", %{state: :running, health: :healthy}),
           svc("qbit1", %{state: :running, health: :healthy})
         ]}
      end)

      start_and_sync!()

      refute_receive {:published, "vpn1"}, 300
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
      assert_receive {:unpublished, "rogue1"}, 2_000
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

      assert_receive {:unpublished, "rogue1"}, 2_000
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
      assert_receive {:unpublished, "rogue1"}, 2_000

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
