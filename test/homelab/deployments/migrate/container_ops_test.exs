defmodule Homelab.Deployments.Migrate.ContainerOpsTest do
  @moduledoc """
  `ContainerOps` is a pure behaviour describing the container lifecycle ops the
  quiesce/resume steps depend on. It has no logic, so this pins the CONTRACT:
  the exact callbacks/arities that the live impl (`ContainerControl`) and the
  test stubs (see quiesce_resume_test.exs) must satisfy, plus a demonstration
  that a conforming stub can be injected via the documented config seam.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.ContainerOps

  defmodule StubOps do
    @behaviour ContainerOps

    @impl true
    def restart_policy(_id), do: {:ok, "always"}

    @impl true
    def set_restart_policy(_id, _name), do: :ok

    @impl true
    def stop(_id, _timeout_seconds), do: :ok

    @impl true
    def start(_id), do: :ok

    @impl true
    def env(_id), do: {:ok, %{}}

    @impl true
    def image_env(_image), do: {:ok, %{}}

    @impl true
    def port_bindings(_id), do: {:ok, []}
  end

  test "defines the lifecycle + inspection callbacks with documented arities" do
    Code.ensure_loaded!(ContainerOps)

    callbacks = MapSet.new(ContainerOps.behaviour_info(:callbacks))

    assert callbacks ==
             MapSet.new(
               restart_policy: 1,
               set_restart_policy: 2,
               stop: 2,
               start: 1,
               env: 1,
               image_env: 1,
               port_bindings: 1
             )
  end

  test "a conforming stub satisfies every callback shape" do
    assert {:ok, "always"} = StubOps.restart_policy("c")
    assert :ok = StubOps.set_restart_policy("c", "no")
    assert :ok = StubOps.stop("c", 60)
    assert :ok = StubOps.start("c")
  end
end
