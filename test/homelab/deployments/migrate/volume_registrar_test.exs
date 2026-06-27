defmodule Homelab.Deployments.Migrate.VolumeRegistrarTest do
  @moduledoc """
  `VolumeRegistrar` is a pure behaviour: it defines the `ensure_volume/2` and
  `remove_volume/1` callbacks that the migration handler resolves at runtime
  (the production impl is `PermanentHome`, tests inject a stub). There is no
  logic of its own to exercise, so these tests pin the behaviour CONTRACT — the
  set of callbacks and arities downstream code and stubs must satisfy.
  """

  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.VolumeRegistrar

  # A minimal stub proving the behaviour is implementable as documented and that
  # `ensure_volume/2` / `remove_volume/1` accept/return the documented shapes.
  defmodule StubRegistrar do
    @behaviour VolumeRegistrar

    @impl true
    def ensure_volume(service, container_path) do
      {:ok, %{"name" => "homelab_#{service}", "container_path" => container_path}}
    end

    @impl true
    def remove_volume(_name), do: :ok
  end

  test "defines exactly the ensure_volume/2 and remove_volume/1 callbacks" do
    Code.ensure_loaded!(VolumeRegistrar)

    callbacks = MapSet.new(VolumeRegistrar.behaviour_info(:callbacks))
    assert callbacks == MapSet.new(ensure_volume: 2, remove_volume: 1)
  end

  test "a conforming implementation returns {:ok, map} from ensure_volume/2" do
    assert {:ok, vol} = StubRegistrar.ensure_volume("postgres", "/var/lib/postgresql/data")
    assert is_map(vol)
    assert vol["container_path"] == "/var/lib/postgresql/data"
  end

  test "a conforming implementation returns :ok from remove_volume/1" do
    assert :ok = StubRegistrar.remove_volume("homelab_postgres")
  end
end
