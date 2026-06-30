defmodule Homelab.Deployments.Migrate.CopyEngineTest do
  @moduledoc """
  `CopyEngine` is a pure behaviour: a single `migrate/3` callback that copies a
  data dir to its permanent home and returns a verification proof map. It has no
  shared/default logic of its own — the real work lives in the concrete engines
  (`LocalCopyEngine`, `ContainerCopyEngine`), each with their own tests. So this
  file pins the behaviour CONTRACT and confirms the documented concrete engines
  actually conform to it.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.CopyEngine

  test "defines exactly the migrate/3 callback" do
    Code.ensure_loaded!(CopyEngine)

    callbacks = MapSet.new(CopyEngine.behaviour_info(:callbacks))
    assert callbacks == MapSet.new(migrate: 3)
  end

  test "the documented concrete engines declare the CopyEngine behaviour" do
    for impl <- [
          Homelab.Deployments.Migrate.LocalCopyEngine,
          Homelab.Deployments.Migrate.ContainerCopyEngine
        ] do
      Code.ensure_loaded!(impl)
      behaviours = impl.module_info(:attributes)[:behaviour] || []

      assert CopyEngine in behaviours,
             "#{inspect(impl)} should declare the CopyEngine behaviour"

      assert function_exported?(impl, :migrate, 2) or function_exported?(impl, :migrate, 3),
             "#{inspect(impl)} should export a migrate function"
    end
  end
end
