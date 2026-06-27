defmodule Homelab.Services.DockerEventListenerTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Services.DockerEventListener
  alias Homelab.Deployments

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  # --- Helpers for driving the GenServer's stream path without a Docker daemon ---
  #
  # The listener's data path is entirely private (`split_lines`,
  # `handle_docker_event`, `parse_exit_code`, `apply_event`). The only seam that
  # reaches it without editing lib/ is `handle_info/2`: once `state.stream_resp`
  # is a `%Req.Response{}`, every inbound message is fed to `Req.parse_message/2`,
  # which simply invokes the response's `stream_fun`. So we hand the listener a
  # synthetic async response whose `stream_fun` echoes back the chunk list we
  # embed in the message — letting us push real NDJSON bytes through the genuine
  # buffer/parse/route/apply pipeline.

  # A %Req.Response{} whose stream_fun turns `{:fake_chunks, chunks}` messages
  # into `{:ok, chunks}` (exactly the contract `handle_info/2` expects).
  defp fake_stream_resp do
    ref = make_ref()

    %Req.Response{
      status: 200,
      headers: %{},
      body: %Req.Response.Async{
        pid: self(),
        ref: ref,
        stream_fun: fn _ref, message ->
          case message do
            {:fake_chunks, chunks} -> {:ok, chunks}
            _ -> :unknown
          end
        end,
        cancel_fun: fn _ref -> :ok end
      }
    }
  end

  # Boots a listener whose `:connect` stores our synthetic stream response, then
  # waits until it is actually connected so subsequent chunk messages take the
  # data path.
  defp start_connected_listener do
    # The listener's `:connect` runs in the GenServer's OWN process, so a
    # test-process `Process.put(:docker_client, ...)` can't reach it. Instead we
    # pass the mock as a start option; the listener sets it in its own process
    # dict during init (a no-op in production). This mutates NO global state, so
    # it can't race concurrent tests. `set_mox_global` lets the GenServer process
    # call the mock's expectations.
    stub(Homelab.Mocks.Orchestrator, :list_services, fn -> {:ok, []} end)
    stub(Homelab.Mocks.Orchestrator, :publish, fn _ -> :ok end)
    stub(Homelab.Mocks.Orchestrator, :unpublish, fn _ -> :ok end)

    resp = fake_stream_resp()
    stub(Homelab.Mocks.DockerClient, :stream_events, fn _filters, _opts -> {:ok, resp} end)

    pid = start_supervised!({DockerEventListener, [docker_client: Homelab.Mocks.DockerClient]})

    wait_until_connected(pid)
    pid
  end

  defp wait_until_connected(pid, attempts \\ 50)
  defp wait_until_connected(_pid, 0), do: flunk("listener never connected to the (fake) stream")

  defp wait_until_connected(pid, attempts) do
    state = :sys.get_state(pid)

    if state.connected and match?(%Req.Response{}, state.stream_resp) do
      :ok
    else
      Process.sleep(10)
      wait_until_connected(pid, attempts - 1)
    end
  end

  # Pushes one or more NDJSON-encoded events through the stream as a single data chunk.
  defp push_events(pid, events) do
    data = events |> Enum.map(&Jason.encode!/1) |> Enum.map(&(&1 <> "\n")) |> Enum.join()
    push_chunks(pid, [{:data, data}])
  end

  defp push_chunks(pid, chunks) do
    send(pid, {:fake_chunks, chunks})
    # Round-trip through the GenServer so the chunk is fully processed before we assert.
    _ = :sys.get_state(pid)
    :ok
  end

  defp container_event(action, deployment_id, extra_attrs \\ %{}) do
    %{
      "Type" => "container",
      "Action" => action,
      "Actor" => %{
        "Attributes" =>
          Map.merge(%{"homelab.deployment_id" => to_string(deployment_id)}, extra_attrs)
      }
    }
  end

  defp insert_deployment(status) do
    insert(:deployment, status: status, domain: "app.tenant.homelab.local")
  end

  defp reload_status(id) do
    {:ok, d} = Deployments.get_deployment(id)
    d.status
  end

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

  describe "split_lines via the stream buffer" do
    test "splits complete newline-delimited events and retains a partial line" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      # Two complete events plus a dangling partial (no trailing newline). The
      # partial must be buffered and NOT routed yet.
      complete = container_event("start", d.id)
      partial = container_event("health_status: healthy", d.id)

      data =
        Jason.encode!(complete) <>
          "\n" <> Jason.encode!(complete) <> "\n" <> String.slice(Jason.encode!(partial), 0..10)

      push_chunks(pid, [{:data, data}])

      # The completed "start" event was applied (pending -> deploying); the
      # partial healthy event has NOT been applied yet.
      assert reload_status(d.id) == :deploying
      assert_received {:deployment_status, _, :deploying}
      refute_received {:deployment_status, _, :running}

      # The buffer retains exactly the partial fragment.
      assert :sys.get_state(pid).buffer == String.slice(Jason.encode!(partial), 0..10)
    end

    test "a partial line completed by a later chunk is then routed" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      json = Jason.encode!(container_event("start", d.id))
      {first, second} = String.split_at(json, 12)

      # First chunk: no newline yet -> nothing routed, whole thing buffered.
      push_chunks(pid, [{:data, first}])
      assert reload_status(d.id) == :pending
      assert :sys.get_state(pid).buffer == first

      # Second chunk completes the line.
      push_chunks(pid, [{:data, second <> "\n"}])
      assert reload_status(d.id) == :deploying
      assert :sys.get_state(pid).buffer == ""
      assert_received {:deployment_status, _, :deploying}
    end

    test "skips blank and malformed lines without crashing" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      good = Jason.encode!(container_event("start", d.id))
      data = "\n   \nnot json at all\n" <> good <> "\n"

      push_chunks(pid, [{:data, data}])

      assert reload_status(d.id) == :deploying
      assert Process.alive?(pid)
    end
  end

  describe "handle_docker_event routing" do
    test "ignores non-container event types" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      push_events(pid, [
        %{
          "Type" => "network",
          "Action" => "start",
          "Actor" => %{"Attributes" => %{"homelab.deployment_id" => to_string(d.id)}}
        }
      ])

      assert reload_status(d.id) == :pending
    end

    test "ignores container events with no homelab.deployment_id attribute" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      push_events(pid, [
        %{"Type" => "container", "Action" => "start", "Actor" => %{"Attributes" => %{}}}
      ])

      assert reload_status(d.id) == :pending
    end

    test "ignores a non-integer deployment_id attribute" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      push_events(pid, [container_event("start", "not-a-number")])

      assert reload_status(d.id) == :pending
      assert Process.alive?(pid)
    end

    test "ignores an event for a deployment_id that does not exist" do
      pid = start_connected_listener()
      # Far-future id that no row uses.
      push_events(pid, [container_event("start", 999_999_999)])
      assert Process.alive?(pid)
    end
  end

  describe "apply_event lifecycle transitions" do
    test "start: pending -> deploying and broadcasts :deploying" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      push_events(pid, [container_event("start", d.id)])

      assert reload_status(d.id) == :deploying
      assert_receive {:deployment_status, id, :deploying}
      assert id == d.id
    end

    test "start: is a no-op for a deployment not in :pending" do
      pid = start_connected_listener()
      d = insert_deployment(:running)

      push_events(pid, [container_event("start", d.id)])

      # The guard only allows pending -> deploying.
      assert reload_status(d.id) == :running
    end

    test "health_status: healthy -> running, publishes, and broadcasts :running" do
      pid = start_connected_listener()
      d = insert_deployment(:deploying)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      test_pid = self()

      expect(Homelab.Mocks.Orchestrator, :publish, fn _network ->
        send(test_pid, :published)
        :ok
      end)

      push_events(pid, [container_event("health_status: healthy", d.id)])

      assert reload_status(d.id) == :running
      assert_receive {:deployment_status, _, :running}
      assert_receive :published
    end

    test "health_status: healthy from :pending also transitions to :running" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      push_events(pid, [container_event("health_status: healthy", d.id)])

      assert reload_status(d.id) == :running
    end

    test "health_status: unhealthy -> deploying, unpublishes" do
      pid = start_connected_listener()
      d = insert_deployment(:running)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      test_pid = self()

      expect(Homelab.Mocks.Orchestrator, :unpublish, fn _network ->
        send(test_pid, :unpublished)
        :ok
      end)

      push_events(pid, [container_event("health_status: unhealthy", d.id)])

      assert reload_status(d.id) == :deploying
      assert_receive {:deployment_status, _, :deploying}
      assert_receive :unpublished
    end

    test "die with exit code 0 -> stopped" do
      pid = start_connected_listener()
      d = insert_deployment(:running)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      push_events(pid, [container_event("die", d.id, %{"exitCode" => "0"})])

      assert reload_status(d.id) == :stopped
      assert_receive {:deployment_status, _, :stopped}
    end

    test "die with a non-zero exit code -> failed and records the error" do
      pid = start_connected_listener()
      d = insert_deployment(:running)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      push_events(pid, [container_event("die", d.id, %{"exitCode" => "137"})])

      assert reload_status(d.id) == :failed
      assert_receive {:deployment_status, _, :failed}

      {:ok, reloaded} = Deployments.get_deployment(d.id)
      assert reloaded.error_message =~ "137"
    end

    test "die is a no-op when already stopped" do
      pid = start_connected_listener()
      d = insert_deployment(:stopped)

      push_events(pid, [container_event("die", d.id, %{"exitCode" => "1"})])

      assert reload_status(d.id) == :stopped
    end

    test "die with a missing exitCode is treated as non-zero (failed)" do
      pid = start_connected_listener()
      d = insert_deployment(:running)

      # No exitCode attribute -> parse_exit_code(nil) == 1 -> failed.
      push_events(pid, [container_event("die", d.id)])

      assert reload_status(d.id) == :failed
    end

    test "die with an integer exitCode of 0 -> stopped" do
      pid = start_connected_listener()
      d = insert_deployment(:running)

      # Docker normally sends strings, but parse_exit_code/1 also accepts ints.
      push_events(pid, [container_event("die", d.id, %{"exitCode" => 0})])

      assert reload_status(d.id) == :stopped
    end

    test "die with an unparseable exitCode string -> failed (defaults to 1)" do
      pid = start_connected_listener()
      d = insert_deployment(:running)

      push_events(pid, [container_event("die", d.id, %{"exitCode" => "nonsense"})])

      assert reload_status(d.id) == :failed
    end

    test "stop -> stopped" do
      pid = start_connected_listener()
      d = insert_deployment(:running)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      push_events(pid, [container_event("stop", d.id)])

      assert reload_status(d.id) == :stopped
      assert_receive {:deployment_status, _, :stopped}
    end

    test "kill -> stopped" do
      pid = start_connected_listener()
      d = insert_deployment(:running)
      Phoenix.PubSub.subscribe(Homelab.PubSub, DockerEventListener.topic())

      push_events(pid, [container_event("kill", d.id)])

      assert reload_status(d.id) == :stopped
      assert_receive {:deployment_status, _, :stopped}
    end

    test "an unhandled action is a no-op" do
      pid = start_connected_listener()
      d = insert_deployment(:running)

      push_events(pid, [container_event("pause", d.id)])

      assert reload_status(d.id) == :running
    end
  end

  describe "stream control chunks" do
    test "a :done chunk schedules a reconnect and clears the stream" do
      pid = start_connected_listener()

      push_chunks(pid, [:done])

      state = :sys.get_state(pid)
      assert state.stream_resp == nil
      refute state.connected
      assert Process.alive?(pid)
    end

    test "an {:error, reason} chunk schedules a reconnect and clears the stream" do
      pid = start_connected_listener()

      push_chunks(pid, [{:error, :closed}])

      state = :sys.get_state(pid)
      assert state.stream_resp == nil
      refute state.connected
      assert Process.alive?(pid)
    end

    test "a :trailers chunk is ignored and the stream keeps running" do
      pid = start_connected_listener()
      d = insert_deployment(:pending)

      # Trailers interleaved with a real data event: the data still routes.
      push_chunks(pid, [
        {:trailers, %{"x" => "y"}},
        {:data, Jason.encode!(container_event("start", d.id)) <> "\n"}
      ])

      assert reload_status(d.id) == :deploying
      assert :sys.get_state(pid).connected
    end
  end
end
