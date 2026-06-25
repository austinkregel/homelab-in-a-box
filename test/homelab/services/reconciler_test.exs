defmodule Homelab.Services.ReconcilerTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
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
    test "severs an orphan's route immediately and removes it after the grace period" do
      Application.put_env(:homelab, :reconciler, orphan_grace_ms: 0)
      record_orchestrator_io(self())

      orphan =
        svc("rogue1", %{
          labels: %{
            "homelab.managed" => "true",
            "homelab.tenant" => "acme",
            "homelab.app" => "ghost"
          }
        })

      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, [orphan]} end)

      # First pass: detected -> route severed + alerted.
      start_and_sync!()
      assert_receive {:unpublished, "homelab_acme_ghost_net"}, 2_000
      assert Repo.aggregate(Notification, :count, :id) >= 1

      # Second pass: grace elapsed -> removed.
      :ok = Reconciler.sync_now()
      assert_receive {:undeployed, "rogue1"}, 2_000
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
