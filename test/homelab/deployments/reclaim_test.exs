defmodule Homelab.Deployments.ReclaimTest do
  @moduledoc """
  Deployments stranded by switching the orchestrator off Swarm.

  Grounded in a real case on kratos: `homelab_identity_authair-redis.1.rn5tdqtj3oix74vlqo868cphd`
  running happily, carrying only `com.docker.swarm.*` labels, while the deployment holding
  its service id was marked `:failed` with "Container not found".
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory
  import Mox

  alias Homelab.Deployments
  alias Homelab.Deployments.Reclaim

  @moduletag :capture_log

  setup :verify_on_exit!

  @service_id "g80c1na7x6snxs3j1p5qeqdr2"
  @task_id "rn5tdqtj3oix74vlqo868cphd"

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerEngine)
    Application.put_env(:homelab, :reclaim_task_interval_ms, 1)
    Application.put_env(:homelab, :reclaim_task_timeout_ms, 50)

    on_exit(fn ->
      Application.put_env(:homelab, :orchestrator, Homelab.Mocks.Orchestrator)
      Application.delete_env(:homelab, :reclaim_task_interval_ms)
      Application.delete_env(:homelab, :reclaim_task_timeout_ms)
    end)

    deployment =
      insert(:deployment,
        app_template: insert(:app_template, slug: "authair-redis", name: "Redis"),
        external_id: @service_id,
        status: :failed
      )

    %{deployment: deployment}
  end

  defp task_container do
    %{
      "Id" => "15135c2e831a",
      "Names" => ["/homelab_identity_authair-redis.1.#{@task_id}"],
      "Labels" => %{
        "com.docker.swarm.service.id" => @service_id,
        "com.docker.swarm.service.name" => "homelab_identity_authair-redis"
      }
    }
  end

  defp services_response,
    do: [%{"ID" => @service_id, "Spec" => %{"Name" => "homelab_identity_authair-redis"}}]

  describe "stranded/0" do
    test "finds a deployment whose external_id is a live swarm service" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/services", _opts -> {:ok, services_response()}
        "/containers/json?all=true&filters=" <> _rest, _opts -> {:ok, [task_container()]}
      end)

      assert [entry] = Reclaim.stranded()
      assert entry.service_id == @service_id
      assert entry.service_name == "homelab_identity_authair-redis"
      assert [container] = entry.containers
      assert container["Id"] == "15135c2e831a"
    end

    test "is empty while Swarm is still the active orchestrator" do
      # Nothing is stranded then — the driver that owns these workloads is in charge.
      Application.put_env(:homelab, :orchestrator, Homelab.Orchestrators.DockerSwarm)

      assert Reclaim.stranded() == []
    end

    test "a plain Engine daemon is not an error" do
      # `/services` on a non-manager answers 503 "this node is not a swarm manager". That is
      # the ordinary case for most installs and must not surface as a failure.
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/services", _opts -> {:error, {:http_error, 503, "not a swarm manager"}}
      end)

      assert Reclaim.stranded() == []
    end

    test "a deployment whose external_id is a real container is left alone" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/services", _opts -> {:ok, services_response()}
      end)

      {:ok, _} =
        Deployments.update_deployment(
          Deployments.get_deployment!(hd(Homelab.Repo.all(Homelab.Deployments.Deployment)).id),
          %{external_id: "a-real-container-id"}
        )

      assert Reclaim.stranded() == []
    end
  end

  describe "reclaim/1" do
    test "removes the service, waits for the task, then redeploys" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :delete, fn "/services/" <> id, _opts ->
        send(test_pid, {:service_removed, id})
        {:ok, %{}}
      end)

      # First poll still sees the task, second does not — the window this exists to close.
      {:ok, counter} = Agent.start_link(fn -> 0 end)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true&filters=" <> _rest, _opts ->
          n = Agent.get_and_update(counter, &{&1, &1 + 1})
          if n == 0, do: {:ok, [task_container()]}, else: {:ok, []}

        _path, _opts ->
          {:ok, %{}}
      end)

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn spec ->
        send(test_pid, {:deployed, spec.service_name})
        {:ok, "new-container-id"}
      end)

      # The deploy itself goes through the configured orchestrator; point it at the mock so
      # this test is about ORDER, not about the Engine driver's payload.
      Application.put_env(:homelab, :orchestrator, Homelab.Mocks.Orchestrator)

      deployment =
        Deployments.get_deployment!(hd(Homelab.Repo.all(Homelab.Deployments.Deployment)).id)

      assert {:ok, reclaimed} = Reclaim.reclaim(deployment)

      assert_received {:service_removed, @service_id}
      assert_received {:deployed, _name}
      assert reclaimed.external_id == "new-container-id"
    end

    test "a service that cannot be removed does NOT fall through to a deploy" do
      # The two-writer case: the swarm task keeps running and a second container mounts the
      # same named volumes. Refusing to deploy is the only safe answer.
      stub(Homelab.Mocks.DockerClient, :delete, fn "/services/" <> _id, _opts ->
        {:error, {:http_error, 500, "daemon on fire"}}
      end)

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> flunk("must not deploy while the swarm service is up") end)

      deployment =
        Deployments.get_deployment!(hd(Homelab.Repo.all(Homelab.Deployments.Deployment)).id)

      assert {:error, {:service_removal_failed, @service_id, _reason}} =
               Reclaim.reclaim(deployment)

      # Still pointing at the service, so it is still reported as stranded rather than lost.
      assert Deployments.get_deployment!(deployment.id).external_id == @service_id
    end

    test "a task that never stops is refused rather than raced" do
      stub(Homelab.Mocks.DockerClient, :delete, fn "/services/" <> _id, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true&filters=" <> _rest, _opts -> {:ok, [task_container()]}
        _path, _opts -> {:ok, %{}}
      end)

      Homelab.Mocks.Orchestrator
      |> stub(:deploy, fn _spec -> flunk("must not deploy while a task container is alive") end)

      deployment =
        Deployments.get_deployment!(hd(Homelab.Repo.all(Homelab.Deployments.Deployment)).id)

      assert {:error, {:tasks_still_running, @service_id, _ids}} = Reclaim.reclaim(deployment)
    end

    test "a deployment with no external_id has nothing to reclaim" do
      assert {:error, :nothing_to_reclaim} =
               Reclaim.reclaim(%Homelab.Deployments.Deployment{external_id: nil})
    end
  end
end
