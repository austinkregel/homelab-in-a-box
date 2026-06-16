defmodule Homelab.Storage.Zfs.HostAgent do
  @moduledoc """
  Production `Homelab.Storage.Zfs` implementation. Sends JSON-RPC requests
  to the host-side `homelab-zfs-agent` daemon over a Unix socket.

  Protocol:

  * Request:  `{"id": <int>, "method": "<name>", "params": {...}}\\n`
  * Response: `{"id": <int>, "result": {...}}\\n` or
              `{"id": <int>, "error": {"code": ..., "message": ...}}\\n`

  The first call on a connection performs a `hello` handshake to verify the
  agent's `protocol_version` matches `@client_protocol_version`. If the agent
  is unavailable (socket missing, refused, wrong version), every callback
  returns `{:error, :agent_unavailable}` (or a more specific tag) so the
  control plane can surface the condition in the UI rather than crash.

  Concurrency: this module is stateless. Each call opens a fresh socket
  connection, performs the handshake, sends one request, reads one
  response, and closes. The agent itself is the per-pool serialization
  point — there is no need for client-side mutexes.
  """

  @behaviour Homelab.Storage.Zfs

  require Logger

  @client_protocol_version 1
  @default_socket "/run/homelab/zfs.sock"
  @recv_timeout 60_000
  @connect_timeout 5_000

  # --- Behaviour callbacks ---

  @impl true
  def protocol_version do
    case request("hello", %{"client_version" => @client_protocol_version}) do
      {:ok, %{"protocol_version" => v}} when is_integer(v) -> {:ok, v}
      {:ok, other} -> {:error, {:bad_hello, other}}
      {:error, _} = err -> err
    end
  end

  @impl true
  def list_pools do
    with {:ok, pools} <- request("pool.list", %{}) do
      {:ok, Enum.map(pools, &normalize_pool_info/1)}
    end
  end

  @impl true
  def create_pool(name, vdev, opts) when is_binary(name) and is_list(vdev) and is_map(opts) do
    request("pool.create", %{
      "name" => name,
      "vdev" => vdev,
      "options" => normalize_pool_opts(opts)
    })
    |> ok_or_error()
  end

  @impl true
  def import_pool(name, opts) do
    request("pool.import", %{"name" => name, "options" => Map.new(opts)})
    |> ok_or_error()
  end

  @impl true
  def export_pool(name) do
    request("pool.export", %{"name" => name})
    |> ok_or_error()
  end

  @impl true
  def pool_status(name) do
    case request("pool.status", %{"name" => name}) do
      {:ok, info} -> {:ok, normalize_pool_info(info)}
      err -> err
    end
  end

  @impl true
  def scrub_pool(name) do
    request("pool.scrub", %{"name" => name}) |> ok_or_error()
  end

  @impl true
  def dataset_exists?(name) do
    case request("dataset.exists", %{"name" => name}) do
      {:ok, %{"exists" => exists}} -> exists == true
      _ -> false
    end
  end

  @impl true
  def create_dataset(name, opts) when is_binary(name) and is_map(opts) do
    request("dataset.create", %{
      "name" => name,
      "options" => normalize_dataset_opts(opts)
    })
    |> ok_or_error()
  end

  @impl true
  def destroy_dataset(name, opts) do
    request("dataset.destroy", %{"name" => name, "options" => Map.new(opts)})
    |> ok_or_error()
  end

  @impl true
  def list_datasets(parent) do
    case request("dataset.list", %{"parent" => parent}) do
      {:ok, datasets} -> {:ok, Enum.map(datasets, &normalize_dataset_info/1)}
      err -> err
    end
  end

  @impl true
  def get_property(name, property) do
    case request("dataset.get_property", %{"name" => name, "property" => property}) do
      {:ok, %{"value" => v}} -> {:ok, to_string(v)}
      err -> err
    end
  end

  @impl true
  def set_property(name, property, value) do
    request("dataset.set_property", %{
      "name" => name,
      "property" => property,
      "value" => to_string(value)
    })
    |> ok_or_error()
  end

  @impl true
  def snapshot(dataset, snap_name) do
    case request("snapshot.create", %{"dataset" => dataset, "snapshot" => snap_name}) do
      {:ok, %{"full_name" => full}} -> {:ok, full}
      {:ok, _} -> {:ok, "#{dataset}@#{snap_name}"}
      err -> err
    end
  end

  @impl true
  def destroy_snapshot(name) do
    request("snapshot.destroy", %{"name" => name}) |> ok_or_error()
  end

  @impl true
  def list_snapshots(dataset) do
    case request("snapshot.list", %{"dataset" => dataset}) do
      {:ok, snaps} -> {:ok, Enum.map(snaps, &normalize_snapshot_info/1)}
      err -> err
    end
  end

  @impl true
  def clone(snapshot, target, opts) do
    request("snapshot.clone", %{
      "snapshot" => snapshot,
      "target" => target,
      "options" => normalize_dataset_opts(opts)
    })
    |> ok_or_error()
  end

  @impl true
  def rollback(snapshot) do
    request("snapshot.rollback", %{"snapshot" => snapshot}) |> ok_or_error()
  end

  @impl true
  def send_stream(snapshot, opts) do
    params = %{
      "snapshot" => snapshot,
      "incremental_from" => Keyword.get(opts, :incremental_from),
      "raw" => Keyword.get(opts, :raw, false),
      "large_block" => Keyword.get(opts, :large_block, false),
      "compressed" => Keyword.get(opts, :compressed, false)
    }

    case open_streaming_request("send.stream", params) do
      {:ok, stream} -> {:ok, stream}
      err -> err
    end
  end

  @impl true
  def receive_stream(target, enumerable, opts) do
    params = %{"target" => target, "options" => Map.new(opts)}

    with {:ok, socket} <- connect_and_handshake() do
      try do
        request_id = next_id()

        request_line =
          encode!(%{"id" => request_id, "method" => "recv.begin", "params" => params})

        :ok = :gen_tcp.send(socket, [request_line, ?\n])

        case recv_line(socket) do
          {:ok, %{"id" => ^request_id, "result" => %{"ready" => true}}} ->
            stream_into_socket(socket, enumerable)
            finalize_recv(socket, request_id)

          {:ok, %{"id" => ^request_id, "error" => err}} ->
            {:error, {:agent_error, err}}

          other ->
            {:error, {:protocol_error, other}}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @impl true
  def load_key(dataset, opts) do
    request("key.load", %{"dataset" => dataset, "options" => Map.new(opts)})
    |> ok_or_error()
  end

  @impl true
  def unload_key(dataset) do
    request("key.unload", %{"dataset" => dataset}) |> ok_or_error()
  end

  @impl true
  def change_key(dataset, opts) do
    request("key.change", %{"dataset" => dataset, "options" => Map.new(opts)})
    |> ok_or_error()
  end

  @impl true
  def mount(dataset) do
    request("dataset.mount", %{"dataset" => dataset}) |> ok_or_error()
  end

  @impl true
  def unmount(dataset) do
    request("dataset.unmount", %{"dataset" => dataset}) |> ok_or_error()
  end

  # --- Public helpers (also used by Disks.Lsblk + Adoption.Importer) ---

  @doc """
  Issues a single JSON-RPC request to the host agent. Public so adjacent
  host-mediated modules (Disks.Lsblk, Adoption.Importer) can share one
  connection model rather than reinventing it.
  """
  @spec request(String.t(), map()) :: {:ok, term()} | {:error, term()}
  def request(method, params) when is_binary(method) and is_map(params) do
    with {:ok, socket} <- connect_and_handshake() do
      try do
        id = next_id()
        line = encode!(%{"id" => id, "method" => method, "params" => params})
        :ok = :gen_tcp.send(socket, [line, ?\n])

        case recv_line(socket) do
          {:ok, %{"id" => ^id, "result" => result}} -> {:ok, result}
          {:ok, %{"id" => ^id, "error" => err}} -> {:error, {:agent_error, err}}
          {:error, _} = err -> err
          other -> {:error, {:protocol_error, other}}
        end
      after
        :gen_tcp.close(socket)
      end
    end
  end

  @doc "Returns the configured socket path. Tests may override via app env."
  @spec socket_path() :: String.t()
  def socket_path do
    Application.get_env(:homelab, :zfs_agent_socket, @default_socket)
  end

  # --- Internals ---

  defp connect_and_handshake do
    path = socket_path()

    if File.exists?(path) do
      do_connect(path)
    else
      {:error, :agent_unavailable}
    end
  end

  defp do_connect(path) do
    case :gen_tcp.connect(
           {:local, String.to_charlist(path)},
           0,
           [:binary, packet: :line, active: false],
           @connect_timeout
         ) do
      {:ok, socket} ->
        case handshake(socket) do
          :ok ->
            {:ok, socket}

          {:error, reason} ->
            :gen_tcp.close(socket)
            {:error, reason}
        end

      {:error, reason} ->
        {:error, {:connect_failed, reason}}
    end
  end

  defp handshake(socket) do
    id = next_id()

    line =
      encode!(%{
        "id" => id,
        "method" => "hello",
        "params" => %{"client_version" => @client_protocol_version}
      })

    :ok = :gen_tcp.send(socket, [line, ?\n])

    case recv_line(socket) do
      {:ok, %{"id" => ^id, "result" => %{"protocol_version" => v}}}
      when v == @client_protocol_version ->
        :ok

      {:ok, %{"id" => ^id, "result" => %{"protocol_version" => v}}} ->
        {:error, {:protocol_mismatch, expected: @client_protocol_version, got: v}}

      {:ok, %{"id" => ^id, "error" => err}} ->
        {:error, {:hello_failed, err}}

      other ->
        {:error, {:hello_protocol_error, other}}
    end
  end

  defp open_streaming_request(method, params) do
    with {:ok, socket} <- connect_and_handshake() do
      id = next_id()
      line = encode!(%{"id" => id, "method" => method, "params" => params})
      :ok = :gen_tcp.send(socket, [line, ?\n])

      case recv_line(socket) do
        {:ok, %{"id" => ^id, "result" => %{"streaming" => true}}} ->
          :inet.setopts(socket, packet: :raw, active: false)
          {:ok, stream_chunks(socket)}

        {:ok, %{"id" => ^id, "error" => err}} ->
          :gen_tcp.close(socket)
          {:error, {:agent_error, err}}

        other ->
          :gen_tcp.close(socket)
          {:error, {:protocol_error, other}}
      end
    end
  end

  defp stream_chunks(socket) do
    Stream.resource(
      fn -> socket end,
      fn sock ->
        case :gen_tcp.recv(sock, 0, @recv_timeout) do
          {:ok, chunk} -> {[chunk], sock}
          {:error, :closed} -> {:halt, sock}
          {:error, reason} -> raise "send stream error: #{inspect(reason)}"
        end
      end,
      fn sock -> :gen_tcp.close(sock) end
    )
  end

  defp stream_into_socket(socket, enumerable) do
    Enum.each(enumerable, fn chunk -> :ok = :gen_tcp.send(socket, chunk) end)
  end

  defp finalize_recv(socket, request_id) do
    case recv_line(socket) do
      {:ok, %{"id" => ^request_id, "result" => %{"ok" => true}}} -> :ok
      {:ok, %{"id" => ^request_id, "error" => err}} -> {:error, {:agent_error, err}}
      other -> {:error, {:protocol_error, other}}
    end
  end

  defp recv_line(socket) do
    case :gen_tcp.recv(socket, 0, @recv_timeout) do
      {:ok, line} ->
        line
        |> String.trim_trailing("\n")
        |> Jason.decode()
        |> case do
          {:ok, decoded} -> {:ok, decoded}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {:error, _} = err ->
        err
    end
  end

  defp encode!(data), do: Jason.encode!(data)

  defp next_id, do: System.unique_integer([:positive, :monotonic])

  defp ok_or_error({:ok, _}), do: :ok
  defp ok_or_error({:error, _} = err), do: err

  # --- Normalizers ---

  defp normalize_pool_opts(opts) do
    opts
    |> Map.new(fn {k, v} -> {to_string(k), serialize_opt(v)} end)
  end

  defp normalize_dataset_opts(opts) do
    opts
    |> Map.new(fn {k, v} -> {to_string(k), serialize_opt(v)} end)
  end

  defp serialize_opt(v) when is_atom(v), do: Atom.to_string(v)
  defp serialize_opt(v) when is_integer(v), do: v
  defp serialize_opt(v) when is_boolean(v), do: v
  defp serialize_opt(v), do: to_string(v)

  defp normalize_pool_info(info) do
    %{
      name: info["name"],
      health: parse_health(info["health"]),
      size_bytes: info["size_bytes"] || 0,
      allocated_bytes: info["allocated_bytes"] || 0,
      free_bytes: info["free_bytes"] || 0,
      last_scrub_at: parse_datetime(info["last_scrub_at"])
    }
  end

  defp normalize_dataset_info(info) do
    mp =
      case info["mountpoint"] do
        nil -> :none
        "none" -> :none
        "-" -> :none
        v -> v
      end

    %{
      name: info["name"],
      type: parse_dataset_type(info["type"]),
      mountpoint: mp,
      used_bytes: info["used_bytes"] || 0,
      available_bytes: info["available_bytes"] || 0,
      referenced_bytes: info["referenced_bytes"] || 0,
      encrypted?: info["encrypted"] == true,
      key_loaded?: info["key_loaded"] == true
    }
  end

  defp normalize_snapshot_info(info) do
    %{
      name: info["name"],
      dataset: info["dataset"],
      created_at: parse_datetime(info["created_at"]),
      used_bytes: info["used_bytes"] || 0,
      referenced_bytes: info["referenced_bytes"] || 0
    }
  end

  defp parse_health(h) when is_binary(h) do
    case String.downcase(h) do
      "online" -> :online
      "degraded" -> :degraded
      "faulted" -> :faulted
      "offline" -> :offline
      "removed" -> :removed
      "unavail" -> :unavail
      _ -> :unknown
    end
  end

  defp parse_health(_), do: :unknown

  defp parse_dataset_type("filesystem"), do: :filesystem
  defp parse_dataset_type("volume"), do: :volume
  defp parse_dataset_type(_), do: :filesystem

  defp parse_datetime(nil), do: nil

  defp parse_datetime(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_datetime(unix) when is_integer(unix) do
    case DateTime.from_unix(unix) do
      {:ok, dt} -> dt
      _ -> nil
    end
  end
end
