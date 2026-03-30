defmodule Homelab.Services.DockerEventListenerTest do
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox
  import Homelab.Factory

  alias Homelab.Services.DockerEventListener

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  describe "topic/0" do
    test "returns the PubSub topic" do
      assert DockerEventListener.topic() == "deployments:status"
    end
  end

  describe "startup sync" do
    test "reconciles deployment status from orchestrator" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      _deployment =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :running,
          external_id: "container_123"
        )

      Homelab.Mocks.Orchestrator
      |> expect(:list_services, fn ->
        {:ok, [
          %{
            id: "container_123",
            name: "test-app",
            state: :stopped,
            replicas: 0,
            image: "testapp:latest",
            labels: %{"homelab.managed" => "true"}
          }
        ]}
      end)

      Phoenix.PubSub.subscribe(Homelab.PubSub, "deployments:status")

      pid = start_supervised!({DockerEventListener, []})
      assert is_pid(pid)

      assert_receive {:deployment_status, _, :stopped}, 5_000
    end

    test "handles empty service list gracefully" do
      Homelab.Mocks.Orchestrator
      |> expect(:list_services, fn -> {:ok, []} end)

      pid = start_supervised!({DockerEventListener, []})
      assert is_pid(pid)
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "handles list_services error gracefully" do
      Homelab.Mocks.Orchestrator
      |> expect(:list_services, fn -> {:error, :connection_refused} end)

      log =
        capture_log(fn ->
          pid = start_supervised!({DockerEventListener, []})
          ref = Process.monitor(pid)
          refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
        end)

      assert log =~ "[DockerEventListener] Startup sync failed: :connection_refused"
    end

    test "reconciles running state" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      dep =
        insert(:deployment,
          tenant: tenant,
          app_template: template,
          status: :deploying,
          external_id: "container_run"
        )

      dep_id = dep.id

      Homelab.Mocks.Orchestrator
      |> expect(:list_services, fn ->
        {:ok, [
          %{
            id: "container_run",
            name: "test-app",
            state: :running,
            replicas: 1,
            image: "testapp:latest",
            labels: %{"homelab.managed" => "true"}
          }
        ]}
      end)

      Phoenix.PubSub.subscribe(Homelab.PubSub, "deployments:status")

      pid = start_supervised!({DockerEventListener, []})
      assert is_pid(pid)

      assert_receive {:deployment_status, ^dep_id, :running}, 5_000
    end
  end

  describe "handle_info for Docker events" do
    test "handles unknown messages gracefully" do
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      pid = start_supervised!({DockerEventListener, []})
      send(pid, {:unexpected_message, "test"})

      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "handles reconnect scheduling" do
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      pid = start_supervised!({DockerEventListener, []})
      send(pid, :reconnect)

      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "handles stream done message" do
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      pid = start_supervised!({DockerEventListener, []})
      ref_stream = make_ref()
      send(pid, {ref_stream, :done})

      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end

    test "handles stream error message" do
      Homelab.Mocks.Orchestrator
      |> stub(:list_services, fn -> {:ok, []} end)

      pid = start_supervised!({DockerEventListener, []})
      ref_stream = make_ref()
      send(pid, {ref_stream, {:error, :timeout}})

      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
    end
  end
end
