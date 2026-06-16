defmodule Homelab.Storage.Disks.Fake do
  @moduledoc """
  In-memory fake `Homelab.Storage.Disks` implementation for tests.

  Tests typically use `Homelab.Mocks.Storage.Disks` (Mox) for one-shot
  expectations; this fake exists for the disk-provisioning LiveView tests
  that need stateful enumeration (add disk → list disks → inspect → wipe →
  list again).
  """

  @behaviour Homelab.Storage.Disks

  use Agent

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    initial = %{disks: %{}, signatures: %{}}
    Agent.start_link(fn -> initial end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Test helper: add a fake disk."
  def add_disk(name \\ __MODULE__, disk) do
    Agent.update(name, fn s ->
      %{s | disks: Map.put(s.disks, disk.path, disk)}
    end)
  end

  @doc "Test helper: associate fake signatures with a path."
  def set_signatures(name \\ __MODULE__, path, signatures) do
    Agent.update(name, fn s ->
      %{s | signatures: Map.put(s.signatures, path, signatures)}
    end)
  end

  @doc "Test helper: simulate wiping a disk (clears its signatures)."
  def wipe(name \\ __MODULE__, path) do
    Agent.update(name, fn s ->
      %{s | signatures: Map.put(s.signatures, path, [])}
    end)
  end

  @impl true
  def list_disks do
    {:ok, __MODULE__ |> Agent.get(& &1.disks) |> Map.values()}
  end

  @impl true
  def disk_signatures(path) do
    {:ok, Agent.get(__MODULE__, fn s -> Map.get(s.signatures, path, []) end)}
  end
end
