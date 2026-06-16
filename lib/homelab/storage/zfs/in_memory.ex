defmodule Homelab.Storage.Zfs.InMemory do
  @moduledoc """
  ETS-backed fake `Homelab.Storage.Zfs` implementation for tests that need
  multi-call state continuity (create dataset → snapshot → clone → list).

  For one-shot expectations prefer `Homelab.Mocks.Storage.Zfs` (Mox) — it
  gives per-test, per-call expectations and is easier to assert on. Use
  this fake when verbose Mox setup would obscure the test's intent.

  Each test creates its own state by calling `start_link/1` (which is also
  the supervisor child spec entry point). The fake holds:

    * `pools`  — `%{name => %{vdev, options, health, ...}}`
    * `datasets` — `%{name => %{options, mountpoint, key_loaded?}}`
    * `snapshots` — `%{name => %{dataset, created_at}}`

  Operations are idempotent where ZFS itself is idempotent
  (`create_dataset` of an existing dataset returns `{:error, :already_exists}`,
  `destroy_dataset` of a missing dataset returns `:ok` — matching the
  `-r` semantics our callers expect).
  """

  @behaviour Homelab.Storage.Zfs

  use Agent

  @type state :: %{
          pools: map(),
          datasets: map(),
          snapshots: map(),
          received_streams: list(),
          sent_streams: list()
        }

  @doc """
  Starts a fresh in-memory ZFS state. Tests typically call this with
  `start_supervised!/1`. The agent is registered under
  `Homelab.Storage.Zfs.InMemory` by default; pass `name: ...` to use a
  different name when running multiple isolated instances in one test.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    initial = %{
      pools: %{},
      datasets: %{},
      snapshots: %{},
      received_streams: [],
      sent_streams: []
    }

    Agent.start_link(fn -> initial end, name: name)
  end

  def child_spec(opts) do
    %{
      id: Keyword.get(opts, :name, __MODULE__),
      start: {__MODULE__, :start_link, [opts]},
      restart: :temporary
    }
  end

  @doc "Resets all state. Useful in `setup` blocks of tests that share a fake instance."
  def reset(name \\ __MODULE__) do
    Agent.update(name, fn _ ->
      %{
        pools: %{},
        datasets: %{},
        snapshots: %{},
        received_streams: [],
        sent_streams: []
      }
    end)
  end

  @doc "Test helper: peek at the full fake state."
  def __state__(name \\ __MODULE__), do: Agent.get(name, & &1)

  # --- Behaviour callbacks ---

  @impl true
  def protocol_version, do: {:ok, 1}

  @impl true
  def list_pools do
    pools =
      __MODULE__
      |> Agent.get(& &1.pools)
      |> Enum.map(fn {name, p} ->
        %{
          name: name,
          health: p.health,
          size_bytes: p.size_bytes,
          allocated_bytes: p.allocated_bytes,
          free_bytes: p.size_bytes - p.allocated_bytes,
          last_scrub_at: p.last_scrub_at
        }
      end)

    {:ok, pools}
  end

  @impl true
  def create_pool(name, vdev, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        Map.has_key?(state.pools, name) ->
          {{:error, :pool_exists}, state}

        true ->
          pool = %{
            vdev: vdev,
            options: opts,
            health: :online,
            size_bytes: Map.get(opts, :__fake_size, 1_000_000_000_000),
            allocated_bytes: 0,
            last_scrub_at: nil
          }

          # Root dataset is implicitly created.
          root_dataset = %{
            options: opts,
            mountpoint: "/#{name}",
            type: :filesystem,
            used_bytes: 0,
            available_bytes: pool.size_bytes,
            referenced_bytes: 0,
            encrypted?: Map.get(opts, :encryption, :off) not in [:off, "off", nil],
            key_loaded?: true
          }

          {:ok,
           %{
             state
             | pools: Map.put(state.pools, name, pool),
               datasets: Map.put(state.datasets, name, root_dataset)
           }}
      end
    end)
  end

  @impl true
  def import_pool(name, _opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.pools, name) do
        nil ->
          {{:error, :no_such_pool}, state}

        pool ->
          {:ok, %{state | pools: Map.put(state.pools, name, %{pool | health: :online})}}
      end
    end)
  end

  @impl true
  def export_pool(name) do
    Agent.update(__MODULE__, fn state ->
      %{state | pools: Map.delete(state.pools, name)}
    end)

    :ok
  end

  @impl true
  def pool_status(name) do
    case Agent.get(__MODULE__, & &1.pools[name]) do
      nil ->
        {:error, :no_such_pool}

      pool ->
        {:ok,
         %{
           name: name,
           health: pool.health,
           size_bytes: pool.size_bytes,
           allocated_bytes: pool.allocated_bytes,
           free_bytes: pool.size_bytes - pool.allocated_bytes,
           last_scrub_at: pool.last_scrub_at
         }}
    end
  end

  @impl true
  def scrub_pool(name) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.pools, name) do
        nil ->
          {{:error, :no_such_pool}, state}

        pool ->
          {:ok,
           %{
             state
             | pools: Map.put(state.pools, name, %{pool | last_scrub_at: DateTime.utc_now()})
           }}
      end
    end)
  end

  @impl true
  def dataset_exists?(name) do
    Agent.get(__MODULE__, &Map.has_key?(&1.datasets, name))
  end

  @impl true
  def create_dataset(name, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        Map.has_key?(state.datasets, name) ->
          {{:error, :already_exists}, state}

        not parent_exists?(state.datasets, name) ->
          {{:error, :no_parent}, state}

        true ->
          dataset = %{
            options: opts,
            mountpoint: Map.get(opts, :mountpoint, "/#{name}"),
            type: :filesystem,
            used_bytes: 0,
            available_bytes: 1_000_000_000,
            referenced_bytes: 0,
            encrypted?:
              inherits_encryption?(state, name) or
                Map.get(opts, :encryption, :inherit) not in [:off, "off", :inherit, nil],
            key_loaded?: true
          }

          {:ok, %{state | datasets: Map.put(state.datasets, name, dataset)}}
      end
    end)
  end

  @impl true
  def destroy_dataset(name, opts) do
    recursive? = Keyword.get(opts, :recursive, false)

    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.datasets, name) do
        nil ->
          {:ok, state}

        _ ->
          {to_destroy_datasets, to_destroy_snapshots} =
            collect_descendants(state, name, recursive?)

          new_datasets = Map.drop(state.datasets, to_destroy_datasets)
          new_snapshots = Map.drop(state.snapshots, to_destroy_snapshots)

          {:ok, %{state | datasets: new_datasets, snapshots: new_snapshots}}
      end
    end)
  end

  @impl true
  def list_datasets(parent) do
    datasets =
      Agent.get(__MODULE__, fn state ->
        Enum.filter(state.datasets, fn {name, _info} ->
          parent_matches?(parent, name)
        end)
      end)

    {:ok,
     Enum.map(datasets, fn {name, info} ->
       %{
         name: name,
         type: info.type,
         mountpoint: info.mountpoint,
         used_bytes: info.used_bytes,
         available_bytes: info.available_bytes,
         referenced_bytes: info.referenced_bytes,
         encrypted?: info.encrypted?,
         key_loaded?: info.key_loaded?
       }
     end)}
  end

  @impl true
  def get_property(name, property) do
    Agent.get(__MODULE__, fn state ->
      case Map.get(state.datasets, name) do
        nil ->
          {:error, :no_such_dataset}

        info ->
          val = Map.get(info.options, String.to_atom(property)) || info.options[property]
          {:ok, to_string(val || "-")}
      end
    end)
  end

  @impl true
  def set_property(name, property, value) do
    Agent.get_and_update(__MODULE__, fn state ->
      case Map.get(state.datasets, name) do
        nil ->
          {{:error, :no_such_dataset}, state}

        info ->
          updated_options = Map.put(info.options, String.to_atom(property), value)

          {:ok,
           %{state | datasets: Map.put(state.datasets, name, %{info | options: updated_options})}}
      end
    end)
  end

  @impl true
  def snapshot(dataset, snap_name) do
    full = "#{dataset}@#{snap_name}"

    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        not Map.has_key?(state.datasets, dataset) ->
          {{:error, :no_such_dataset}, state}

        Map.has_key?(state.snapshots, full) ->
          {{:error, :already_exists}, state}

        true ->
          snap = %{
            dataset: dataset,
            created_at: DateTime.utc_now(),
            used_bytes: 0,
            referenced_bytes: 0
          }

          {{:ok, full}, %{state | snapshots: Map.put(state.snapshots, full, snap)}}
      end
    end)
  end

  @impl true
  def destroy_snapshot(name) do
    Agent.update(__MODULE__, fn state ->
      %{state | snapshots: Map.delete(state.snapshots, name)}
    end)

    :ok
  end

  @impl true
  def list_snapshots(dataset) do
    snaps =
      Agent.get(__MODULE__, fn state ->
        state.snapshots
        |> Enum.filter(fn {_name, info} -> info.dataset == dataset end)
        |> Enum.map(fn {name, info} ->
          %{
            name: name,
            dataset: info.dataset,
            created_at: info.created_at,
            used_bytes: info.used_bytes,
            referenced_bytes: info.referenced_bytes
          }
        end)
      end)

    {:ok, snaps}
  end

  @impl true
  def clone(snapshot, target, opts) do
    Agent.get_and_update(__MODULE__, fn state ->
      cond do
        not Map.has_key?(state.snapshots, snapshot) ->
          {{:error, :no_such_snapshot}, state}

        Map.has_key?(state.datasets, target) ->
          {{:error, :already_exists}, state}

        true ->
          dataset = %{
            options: opts,
            mountpoint: Map.get(opts, :mountpoint, "/#{target}"),
            type: :filesystem,
            used_bytes: 0,
            available_bytes: 1_000_000_000,
            referenced_bytes: 0,
            encrypted?: false,
            key_loaded?: true
          }

          {:ok, %{state | datasets: Map.put(state.datasets, target, dataset)}}
      end
    end)
  end

  @impl true
  def rollback(_snapshot), do: :ok

  @impl true
  def send_stream(snapshot, opts) do
    case Agent.get(__MODULE__, &Map.has_key?(&1.snapshots, snapshot)) do
      false ->
        {:error, :no_such_snapshot}

      true ->
        chunks = ["FAKE-SEND-STREAM:", snapshot, ":", inspect(opts)]

        Agent.update(__MODULE__, fn s ->
          %{s | sent_streams: [{snapshot, opts} | s.sent_streams]}
        end)

        {:ok, chunks}
    end
  end

  @impl true
  def receive_stream(target, enumerable, _opts) do
    bytes = enumerable |> Enum.to_list() |> IO.iodata_to_binary()

    Agent.update(__MODULE__, fn state ->
      state =
        if Map.has_key?(state.datasets, target) do
          state
        else
          dataset = %{
            options: %{},
            mountpoint: "/#{target}",
            type: :filesystem,
            used_bytes: byte_size(bytes),
            available_bytes: 1_000_000_000,
            referenced_bytes: byte_size(bytes),
            encrypted?: false,
            key_loaded?: true
          }

          %{state | datasets: Map.put(state.datasets, target, dataset)}
        end

      %{state | received_streams: [{target, bytes} | state.received_streams]}
    end)

    :ok
  end

  @impl true
  def load_key(_dataset, _opts), do: :ok

  @impl true
  def unload_key(_dataset), do: :ok

  @impl true
  def change_key(_dataset, _opts), do: :ok

  @impl true
  def mount(_dataset), do: :ok

  @impl true
  def unmount(_dataset), do: :ok

  # --- Internals ---

  defp parent_exists?(datasets, name) do
    case String.split(name, "/") do
      [_only] ->
        true

      segments ->
        parent =
          segments
          |> Enum.drop(-1)
          |> Enum.join("/")

        Map.has_key?(datasets, parent)
    end
  end

  defp parent_matches?(nil, _name), do: true

  defp parent_matches?(parent, name) do
    name == parent or String.starts_with?(name, parent <> "/")
  end

  defp collect_descendants(state, name, recursive?) do
    descendant_datasets =
      if recursive? do
        state.datasets
        |> Map.keys()
        |> Enum.filter(fn n -> n == name or String.starts_with?(n, name <> "/") end)
      else
        [name]
      end

    snapshots =
      state.snapshots
      |> Enum.filter(fn {_n, info} -> info.dataset in descendant_datasets end)
      |> Enum.map(fn {n, _info} -> n end)

    {descendant_datasets, snapshots}
  end

  defp inherits_encryption?(state, name) do
    case String.split(name, "/", parts: 2) do
      [_root] -> false
      [root, _rest] -> get_in(state, [:datasets, root, :encrypted?]) == true
    end
  end
end
