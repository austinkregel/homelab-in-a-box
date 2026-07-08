defmodule Homelab.Deployments.AdoptionReleaseTest do
  @moduledoc """
  End-to-end adoption: the real phase-1 + phase-2 handlers run through
  `ReleaseRunner` against a mocked orchestrator and in-process copy engine. Proves
  the whole cutover works, that the ORIGINAL container is never removed, and that
  a failure rolls back with the original resumed and the source untouched.
  """
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{AdoptionPlanner, PermanentHome, ReleaseRunner, Releases}

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule StubOps do
    @behaviour Homelab.Deployments.Migrate.ContainerOps
    @impl true
    def restart_policy(id), do: (send(pid(), {:restart_policy, id}); {:ok, "always"})
    @impl true
    def set_restart_policy(id, name), do: (send(pid(), {:set_restart_policy, id, name}); :ok)
    @impl true
    def stop(id, _t), do: (send(pid(), {:stop, id}); :ok)
    @impl true
    def start(id), do: (send(pid(), {:start, id}); :ok)
    @impl true
    def env(_id), do: {:ok, %{"POSTGRES_PASSWORD" => "s3cret", "PATH" => "/usr/bin"}}
    @impl true
    def image_env(_image), do: {:ok, %{"PATH" => "/usr/bin"}}
    @impl true
    def port_bindings(_id), do: {:ok, []}
    defp pid, do: Application.get_env(:homelab, :adopt_e2e_pid)
  end

  defmodule StubRegistrar do
    @behaviour Homelab.Deployments.Migrate.VolumeRegistrar
    @impl true
    def ensure_volume(service, container_path) do
      {:ok, %{name: PermanentHome.volume_name(service, container_path), created: true, device: "x"}}
    end

    @impl true
    def remove_volume(_name), do: :ok
  end

  setup do
    base = Path.join(System.tmp_dir!(), "adopt-e2e-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "data.txt"), "important-bytes")

    Application.put_env(:homelab, :container_ops, StubOps)
    Application.put_env(:homelab, :migrate_volume_registrar, StubRegistrar)
    Application.put_env(:homelab, :managed_root, Path.join(base, "managed"))
    Application.put_env(:homelab, :backup_root, Path.join(base, "backups"))
    Application.put_env(:homelab, :adopt_e2e_pid, self())
    Application.put_env(:homelab, :verify_integrity_timeout_ms, 500)
    Application.put_env(:homelab, :verify_integrity_stable_ms, 5)
    Application.put_env(:homelab, :await_health_interval_ms, 5)

    on_exit(fn ->
      for k <- [
            :container_ops,
            :migrate_volume_registrar,
            :managed_root,
            :backup_root,
            :adopt_e2e_pid,
            :verify_integrity_timeout_ms,
            :verify_integrity_stable_ms,
            :await_health_interval_ms
          ],
          do: Application.delete_env(:homelab, k)

      File.rm_rf(base)
    end)

    %{src: src, base: base}
  end

  # Builds the adopted deployment + a real 8-step release from the planner.
  defp plan_adoption(src) do
    review = %{
      name: "homelab-pg",
      image: "postgres:16",
      user: "999:999",
      restart_policy: "always",
      container_id: "old-pg",
      preserve: [
        %{
          type: "bind",
          source: src,
          target: "/var/lib/postgresql/data",
          mountpoint: src,
          tier: :preserve
        }
      ],
      rebuildable: [],
      out_of_scope: []
    }

    plan = AdoptionPlanner.build_plan([review])
    [service] = plan.services

    tenant = insert(:tenant, slug: "acme")

    template =
      insert(:app_template,
        Map.to_list(Map.merge(service.template_attrs, %{health_check: %{}, required_env: []}))
      )

    deployment =
      insert(:deployment, tenant: tenant, app_template: template, status: :pending, external_id: nil)

    {:ok, release} =
      Releases.plan_release(deployment, service.phase1 ++ service.phase2,
        plan: %{"kind" => "adoption"}
      )

    %{deployment: deployment, release: release}
  end

  test "happy path: full 8-step release lands :running with a new managed id", %{src: src} do
    stub(Homelab.Mocks.Orchestrator, :deploy, fn _spec -> {:ok, "managed-new"} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    %{deployment: deployment, release: release} = plan_adoption(src)

    assert :ok = ReleaseRunner.run(release.id, owner: "t")

    release = Releases.get_release(release.id)
    assert release.status == :running
    assert Enum.all?(release.steps, &(&1.status == :completed))

    deployment = Deployments.get_deployment!(deployment.id)
    assert deployment.external_id == "managed-new"

    # Copied bytes are in the permanent home; the original was stopped, never removed.
    dest = PermanentHome.backing_dir("homelab-pg", "/var/lib/postgresql/data")
    assert File.read!(Path.join(dest, "data.txt")) == "important-bytes"
    assert_received {:stop, "old-pg"}
    refute_received {:undeployed, "old-pg"}

    # Source is untouched.
    assert File.read!(Path.join(src, "data.txt")) == "important-bytes"
  end

  test "deploy failure at cutover rolls back, resumes the original, leaves source intact", %{
    src: src
  } do
    test_pid = self()
    stub(Homelab.Mocks.Orchestrator, :deploy, fn _spec -> {:error, :boom} end)

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    stub(Homelab.Mocks.Orchestrator, :undeploy, fn id ->
      send(test_pid, {:undeployed, id})
      :ok
    end)

    %{deployment: deployment, release: release} = plan_adoption(src)

    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")

    release = Releases.get_release(release.id)
    assert release.status == :rolled_back

    # Original resumed with its original policy; never removed.
    assert_received {:set_restart_policy, "old-pg", "always"}
    assert_received {:start, "old-pg"}
    refute_received {:undeployed, "old-pg"}

    # Row reset; source intact.
    assert Deployments.get_deployment!(deployment.id).external_id == nil
    assert File.read!(Path.join(src, "data.txt")) == "important-bytes"
  end

  test "verify_integrity failure rolls back after a successful deploy", %{src: src} do
    test_pid = self()
    stub(Homelab.Mocks.Orchestrator, :deploy, fn _spec -> {:ok, "managed-new"} end)
    # Deploy succeeds but the replacement never reports running -> verify fails.
    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :stopped, health: :none}}
    end)

    stub(Homelab.Mocks.Orchestrator, :undeploy, fn id ->
      send(test_pid, {:undeployed, id})
      :ok
    end)

    %{deployment: deployment, release: release} = plan_adoption(src)

    assert {:cancel, {:rolled_back, _}} = ReleaseRunner.run(release.id, owner: "t")
    assert Releases.get_release(release.id).status == :rolled_back

    # The managed replacement was undeployed; the original resumed.
    assert_received {:undeployed, "managed-new"}
    assert_received {:start, "old-pg"}
    assert Deployments.get_deployment!(deployment.id).external_id == nil
  end
end
