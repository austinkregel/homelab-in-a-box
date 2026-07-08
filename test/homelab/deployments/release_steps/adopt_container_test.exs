defmodule Homelab.Deployments.ReleaseSteps.AdoptContainerTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{PermanentHome, Releases}
  alias Homelab.Deployments.ReleaseSteps.AdoptContainer

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule StubOps do
    @behaviour Homelab.Deployments.Migrate.ContainerOps

    @impl true
    def restart_policy(id) do
      send(pid(), {:restart_policy, id})
      {:ok, "always"}
    end

    @impl true
    def set_restart_policy(id, name) do
      send(pid(), {:set_restart_policy, id, name})
      :ok
    end

    @impl true
    def stop(id, _t) do
      send(pid(), {:stop, id})
      :ok
    end

    @impl true
    def start(id) do
      send(pid(), {:start, id})
      :ok
    end

    @impl true
    def env(_id), do: {:ok, %{}}
    @impl true
    def image_env(_image), do: {:ok, %{}}

    @impl true
    def port_bindings(id) do
      send(pid(), {:port_bindings, id})
      {:ok, [%{"internal" => "5432", "external" => "5432", "protocol" => "tcp"}]}
    end

    defp pid, do: Application.get_env(:homelab, :adopt_test_pid)
  end

  setup do
    base = Path.join(System.tmp_dir!(), "adoptctr-#{System.unique_integer([:positive])}")
    src = Path.join(base, "src")
    managed_root = Path.join(base, "managed")
    File.mkdir_p!(src)
    File.write!(Path.join(src, "data.txt"), "important")

    Application.put_env(:homelab, :container_ops, StubOps)
    Application.put_env(:homelab, :managed_root, managed_root)
    Application.put_env(:homelab, :adopt_test_pid, self())

    on_exit(fn ->
      Application.delete_env(:homelab, :container_ops)
      Application.delete_env(:homelab, :managed_root)
      Application.delete_env(:homelab, :adopt_test_pid)
      File.rm_rf(base)
    end)

    tenant = insert(:tenant, slug: "acme")

    template =
      insert(:app_template,
        slug: "adopted-pg",
        source: "adopted",
        exposure_mode: :host,
        required_env: [],
        default_env: %{},
        ports: [],
        volumes: [
          %{
            "container_path" => "/var/lib/postgresql/data",
            "source" => PermanentHome.volume_name("homelab-pg", "/var/lib/postgresql/data"),
            "type" => "volume"
          }
        ]
      )

    deployment =
      insert(:deployment, tenant: tenant, app_template: template, status: :pending, external_id: nil)

    targets = [
      %{
        "name" => "homelab-pg",
        "source" => src,
        "container_path" => "/var/lib/postgresql/data",
        "tier" => "preserve"
      }
    ]

    %{deployment: deployment, targets: targets, src: src}
  end

  defp step(deployment, targets) do
    %Homelab.Deployments.ReleaseStep{
      resource_handle: %{
        "container" => "old-pg",
        "restart_policy" => "always",
        "targets" => targets,
        "service" => "homelab-pg"
      }
    }
    |> then(&{&1, %{release: nil, deployment: deployment}})
  end

  test "cuts over: stops old, re-syncs data, deploys managed replacement with secrets", %{
    deployment: deployment,
    targets: targets
  } do
    Releases.put_secret(deployment.id, "POSTGRES_PASSWORD", "s3cret")

    stub(Homelab.Mocks.Orchestrator, :deploy, fn spec ->
      send(self(), {:deploy_env, spec.env})
      {:ok, "new-managed-id"}
    end)

    {s, ctx} = step(deployment, targets)
    assert {:ok, handle} = AdoptContainer.run(s, ctx)

    assert handle["external_id"] == "new-managed-id"
    assert handle["container"] == "old-pg"
    assert handle["original_restart_policy"] == "always"

    # Old container was quiesced+stopped BEFORE the new one deployed.
    assert_received {:set_restart_policy, "old-pg", "no"}
    assert_received {:stop, "old-pg"}
    assert_received {:deploy_env, env}
    assert env["POSTGRES_PASSWORD"] == "s3cret"

    # Data re-synced into the permanent home.
    dest = PermanentHome.backing_dir("homelab-pg", "/var/lib/postgresql/data")
    assert File.read!(Path.join(dest, "data.txt")) == "important"

    # external_id persisted on the row.
    assert Deployments.get_deployment!(deployment.id).external_id == "new-managed-id"
  end

  test "compensate undeploys the replacement and resumes the original (never removes it)", %{
    deployment: deployment
  } do
    test_pid = self()
    stub(Homelab.Mocks.Orchestrator, :undeploy, fn id -> send(test_pid, {:undeployed, id}); :ok end)

    handle = %Homelab.Deployments.ReleaseStep{
      resource_handle: %{
        "external_id" => "new-managed-id",
        "deployment_id" => deployment.id,
        "container" => "old-pg",
        "original_restart_policy" => "always"
      }
    }

    assert :ok = AdoptContainer.compensate(handle, %{release: nil, deployment: deployment})

    # Replacement undeployed; original restarted with its original policy.
    assert_received {:undeployed, "new-managed-id"}
    assert_received {:set_restart_policy, "old-pg", "always"}
    assert_received {:start, "old-pg"}
    # The original id is NEVER passed to undeploy.
    refute_received {:undeployed, "old-pg"}

    assert Deployments.get_deployment!(deployment.id).external_id == nil
  end
end
