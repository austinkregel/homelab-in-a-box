defmodule Homelab.Deployments.ReleaseSteps.VerifyIntegrityTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments.ReleaseSteps.VerifyIntegrity

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    # Tiny windows so the test is fast.
    Application.put_env(:homelab, :verify_integrity_timeout_ms, 200)
    Application.put_env(:homelab, :verify_integrity_stable_ms, 10)
    Application.put_env(:homelab, :await_health_interval_ms, 5)

    on_exit(fn ->
      Application.delete_env(:homelab, :verify_integrity_timeout_ms)
      Application.delete_env(:homelab, :verify_integrity_stable_ms)
      Application.delete_env(:homelab, :await_health_interval_ms)
    end)

    deployment = insert(:deployment, status: :deploying, external_id: "managed-id")
    %{ctx: %{release: nil, deployment: deployment}}
  end

  test "passes when the container is running and stays running", %{ctx: ctx} do
    stub(Homelab.Mocks.Orchestrator, :get_service, fn "managed-id" ->
      {:ok, %{id: "x", state: :running, health: :healthy}}
    end)

    assert {:ok, %{"verified" => true}} = VerifyIntegrity.run(nil, ctx)
  end

  test "fails when the container never becomes ready (timeout)", %{ctx: ctx} do
    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      {:ok, %{id: "x", state: :starting, health: :starting}}
    end)

    assert {:error, {:integrity_failed, _id, :not_ready}} = VerifyIntegrity.run(nil, ctx)
  end

  test "fails when the container dies during the stability window", %{ctx: ctx} do
    # First readiness check passes; after the stability sleep, it's gone.
    counter = :counters.new(1, [])

    stub(Homelab.Mocks.Orchestrator, :get_service, fn _id ->
      n = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)
      if n == 0, do: {:ok, %{state: :running, health: :healthy}}, else: {:error, :not_found}
    end)

    assert {:error, {:integrity_failed, _id, :unstable}} = VerifyIntegrity.run(nil, ctx)
  end
end
