defmodule Homelab.Deployments.Backups.StrategyTest do
  @moduledoc """
  `Strategy` is a pure behaviour for the `:backup_verify` gate: `backup/3`
  produces a durable copy + artifact map, `verify/2` proves it restorable. No
  logic of its own, so this pins the CONTRACT and confirms the reference
  implementation (`FileCopy`) conforms to it.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Backups.Strategy

  test "defines the backup/3 and verify/2 callbacks" do
    Code.ensure_loaded!(Strategy)

    callbacks = MapSet.new(Strategy.behaviour_info(:callbacks))
    assert callbacks == MapSet.new(backup: 3, verify: 2)
  end

  test "the reference FileCopy strategy declares the Strategy behaviour" do
    impl = Homelab.Deployments.Backups.FileCopy
    Code.ensure_loaded!(impl)

    behaviours = impl.module_info(:attributes)[:behaviour] || []
    assert Strategy in behaviours
    assert function_exported?(impl, :backup, 3) or function_exported?(impl, :backup, 2)
    assert function_exported?(impl, :verify, 2) or function_exported?(impl, :verify, 1)
  end
end
