defmodule Homelab.Deployments.ReleaseSteps.QuiesceResumeTest do
  use ExUnit.Case, async: false

  alias Homelab.Deployments.ReleaseSteps.{QuiesceOld, ResumeOld}

  # Stub ops: reports each call to the test process; restart_policy is scripted.
  defmodule StubOps do
    @behaviour Homelab.Deployments.Migrate.ContainerOps

    @impl true
    def restart_policy(id) do
      send(pid(), {:restart_policy, id})
      {:ok, Application.get_env(:homelab, :stub_current_policy, "always")}
    end

    @impl true
    def set_restart_policy(id, name) do
      send(pid(), {:set_restart_policy, id, name})
      Application.get_env(:homelab, :stub_set_policy_result, :ok)
    end

    @impl true
    def stop(id, t) do
      send(pid(), {:stop, id, t})
      :ok
    end

    @impl true
    def start(id) do
      send(pid(), {:start, id})
      :ok
    end

    @impl true
    def env(id) do
      send(pid(), {:env, id})
      {:ok, Application.get_env(:homelab, :stub_container_env, %{})}
    end

    @impl true
    def image_env(image) do
      send(pid(), {:image_env, image})
      {:ok, Application.get_env(:homelab, :stub_image_env, %{})}
    end

    @impl true
    def port_bindings(id) do
      send(pid(), {:port_bindings, id})
      {:ok, Application.get_env(:homelab, :stub_port_bindings, [])}
    end

    defp pid, do: Application.get_env(:homelab, :quiesce_test_pid)
  end

  setup do
    Application.put_env(:homelab, :container_ops, StubOps)
    Application.put_env(:homelab, :quiesce_test_pid, self())
    Application.put_env(:homelab, :quiesce_stop_timeout, 60)

    on_exit(fn ->
      Application.delete_env(:homelab, :container_ops)
      Application.delete_env(:homelab, :quiesce_test_pid)
      Application.delete_env(:homelab, :quiesce_stop_timeout)
      Application.delete_env(:homelab, :stub_current_policy)
      Application.delete_env(:homelab, :stub_set_policy_result)
    end)

    :ok
  end

  defp step(handle), do: %{id: 1, resource_handle: handle}

  # Everything the stub reported, in the order it was called.
  defp drain(acc \\ []) do
    receive do
      msg -> drain([msg | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp index(calls, msg) do
    case Enum.find_index(calls, &(&1 == msg)) do
      nil -> flunk("#{inspect(msg)} was never called; got #{inspect(calls)}")
      i -> i
    end
  end

  describe "QuiesceOld" do
    test "stops BEFORE disabling the restart policy, and records the original" do
      Application.put_env(:homelab, :stub_current_policy, "always")

      assert {:ok, handle} = QuiesceOld.run(step(%{"container" => "pg1"}), %{})
      assert handle["original_restart_policy"] == "always"
      assert handle["container"] == "pg1"

      # `assert_received` scans the whole mailbox, so it cannot see order — compare indices.
      calls = drain()
      assert index(calls, {:stop, "pg1", 60}) < index(calls, {:set_restart_policy, "pg1", "no"})
    end

    test "a policy write that fails does not mask a container left running" do
      Application.put_env(:homelab, :stub_current_policy, "always")
      Application.put_env(:homelab, :stub_set_policy_result, {:error, :cannot_update_stopped})

      assert {:error, {:quiesce_failed, "pg1", :cannot_update_stopped}} =
               QuiesceOld.run(step(%{"container" => "pg1"}), %{})

      assert_received {:stop, "pg1", 60}
    end

    test "compensate restores the original policy and restarts" do
      done = step(%{"container" => "pg1", "original_restart_policy" => "always"})

      assert :ok = QuiesceOld.compensate(done, %{})
      assert_received {:set_restart_policy, "pg1", "always"}
      assert_received {:start, "pg1"}
    end
  end

  describe "ResumeOld" do
    test "restores the planner-supplied policy and starts" do
      assert {:ok, handle} =
               ResumeOld.run(step(%{"container" => "pg1", "restart_policy" => "always"}), %{})

      assert handle["resumed"] == true
      assert_received {:set_restart_policy, "pg1", "always"}
      assert_received {:start, "pg1"}
    end

    test "compensate re-quiesces (disable + stop) so no double-writer survives rollback" do
      done = step(%{"container" => "pg1", "restart_policy" => "always"})

      assert :ok = ResumeOld.compensate(done, %{})

      calls = drain()
      assert index(calls, {:stop, "pg1", 60}) < index(calls, {:set_restart_policy, "pg1", "no"})
    end
  end

  test "quiesce -> resume round-trips the policy back to the original" do
    Application.put_env(:homelab, :stub_current_policy, "unless-stopped")

    {:ok, q} = QuiesceOld.run(step(%{"container" => "c"}), %{})
    original = q["original_restart_policy"]
    assert original == "unless-stopped"

    {:ok, _} = ResumeOld.run(step(%{"container" => "c", "restart_policy" => original}), %{})
    # Last policy write resumes the original.
    assert_received {:set_restart_policy, "c", "no"}
    assert_received {:set_restart_policy, "c", "unless-stopped"}
  end
end
