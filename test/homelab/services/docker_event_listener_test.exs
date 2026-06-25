defmodule Homelab.Services.DockerEventListenerTest do
  use Homelab.DataCase, async: false

  import Mox

  alias Homelab.Services.DockerEventListener

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  describe "topic/0" do
    test "returns the PubSub topic" do
      assert DockerEventListener.topic() == "deployments:status"
    end
  end

  describe "startup" do
    test "starts cleanly without a Reconciler running" do
      # The listener nudges the Reconciler on connect; when none is running that
      # nudge is a safe no-op and the listener must not crash. Convergence itself
      # is exercised in Homelab.Services.ReconcilerTest.
      pid = start_supervised!({DockerEventListener, []})
      assert is_pid(pid)
      ref = Process.monitor(pid)
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 500
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
