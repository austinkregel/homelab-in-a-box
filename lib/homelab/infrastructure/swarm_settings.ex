defmodule Homelab.Infrastructure.SwarmSettings do
  @moduledoc """
  Cluster-level Swarm configuration: read (`GET /swarm`), merge, write
  (`POST /swarm/update`).

  Three properties of the Docker API drive this module's shape.

  1. `POST /swarm/update` takes a *whole* ClusterSpec, not a patch. Every field the
     body omits reverts to the daemon's default — omitting `EncryptionConfig` turns
     auto-lock off, omitting `Raft` throws away a hand-tuned election timeout. So a
     write here is always read-modify-write against the exact spec the daemon just
     returned, overwriting only the handful of leaves we consider safe to touch.

  2. It is optimistically concurrent: the `Version.Index` from `GET /swarm` must be
     passed as `?version=N`, and the daemon rejects a stale one. We re-read
     immediately before each write rather than trusting an index parked in a
     LiveView assign while the user went for coffee.

  3. Durations in the spec are **nanoseconds**. Nobody reasons about certificate
     rotation in nanoseconds, so the form speaks seconds and days and the
     conversion lives here.

  Read/write is split from validation deliberately: `validate/1`, `merge_spec/2`
  and `to_form_values/1` are pure and unit-tested without a daemon.
  """

  alias Homelab.Docker.Client

  @ns_per_second 1_000_000_000
  @ns_per_day 86_400 * @ns_per_second

  # Docker's own defaults, used when a spec omits the key entirely (a fresh
  # `swarm init` does populate all of these, but an older daemon may not).
  @default_task_history 5
  @default_heartbeat_seconds 5
  @default_cert_expiry_days 90

  @doc """
  The editable levers, with the plain-English explanation each one needs.

  This lives next to the validation bounds on purpose: the number a user is
  allowed to type and the sentence telling them what it costs must not drift
  apart. The LiveView renders straight from this list.
  """
  def fields do
    [
      %{
        key: :task_history_retention_limit,
        param: "task_history_retention_limit",
        label: "Task history retention limit",
        unit: "records kept per service",
        default: @default_task_history,
        min: 0,
        max: 1000,
        what:
          "How many finished tasks (crashed, stopped, or replaced containers) Swarm remembers for each service. This is the list behind `docker service ps` — it is how you find out why something died after it has already been replaced.",
        tradeoff:
          "Raising it gives you a longer trail to debug with. Each remembered task is held in the managers' in-memory Raft store, so a large number on a service that crash-loops will grow manager memory. Docker's default is 5; 20–50 is comfortable for a homelab. Set it to 0 and a crashed task disappears without a trace."
      },
      %{
        key: :dispatcher_heartbeat_seconds,
        param: "dispatcher_heartbeat_seconds",
        label: "Agent heartbeat period",
        unit: "seconds",
        default: @default_heartbeat_seconds,
        min: 1,
        max: 60,
        what:
          "How often every node checks in with the managers to say it is alive and to report what its containers are doing.",
        tradeoff:
          "Shorter means the cluster notices a dead node sooner, at the cost of more chatter and manager CPU as node count grows. Longer means a node can be gone for up to this long before its containers are rescheduled elsewhere. Docker's default is 5 seconds; on a small wired LAN there is little reason to change it."
      },
      %{
        key: :node_cert_expiry_days,
        param: "node_cert_expiry_days",
        label: "Node certificate expiry",
        unit: "days",
        default: @default_cert_expiry_days,
        min: 1,
        max: 3650,
        what:
          "Swarm gives every node a TLS certificate to talk to the managers, and rotates it automatically before it expires. This is how long each certificate is valid for.",
        tradeoff:
          "Shorter means a compromised node's credentials stop working sooner, at the cost of more frequent (automatic, invisible) rotation. Docker's default is 90 days. Rotation is handled for you — the risk of a short value is a node that has been powered off for longer than the certificate's lifetime, which then has to re-join the cluster by hand."
      }
    ]
  end

  @doc """
  The levers we deliberately refuse to make editable, with the reason.

  Surfacing these read-only is the point: the user asked what levers exist, and
  "this one exists and here is why you cannot pull it from a web form" is a more
  useful answer than silence.
  """
  def locked_fields(spec) when is_map(spec) do
    raft = Map.get(spec, "Raft", %{})

    [
      %{
        label: "Auto-lock managers",
        value: if(get_in(spec, ["EncryptionConfig", "AutoLockManagers"]), do: "On", else: "Off"),
        why:
          "Encrypts the Raft store at rest. Once enabled, every manager that restarts stays locked until someone types an unlock key — and if that key is lost, the cluster and everything it knows about your services is unrecoverable. That needs a key-escrow flow (show the key, make you confirm you saved it, store it somewhere you can reach when the cluster is down), not a checkbox on a settings page. Use `docker swarm update --autolock=true` at a terminal, where the key is printed to you."
      },
      %{
        label: "Raft election tick",
        value: to_string(Map.get(raft, "ElectionTick") || "—"),
        why:
          "How many missed heartbeats before a manager decides the leader is dead and starts an election. Mistune it on a live cluster and the managers either flap between leaders or fail to notice a real leader failure. Docker's defaults are tuned for a LAN and should be left alone."
      },
      %{
        label: "Raft heartbeat tick",
        value: to_string(Map.get(raft, "HeartbeatTick") || "—"),
        why:
          "How often the Raft leader pings the other managers. Paired with the election tick above — changing one without the other is how you get a cluster that cannot hold a leader."
      },
      %{
        label: "Raft snapshot interval",
        value: to_string(Map.get(raft, "SnapshotInterval") || "—"),
        why:
          "How many Raft log entries between snapshots. Too low and the managers spend their time snapshotting; too high and a manager that restarts takes a long time to catch up, or runs out of memory replaying the log."
      },
      %{
        label: "Raft log entries for slow followers",
        value: to_string(Map.get(raft, "LogEntriesForSlowFollowers") || "—"),
        why:
          "How much log history is kept around for a manager that has fallen behind. Set it too low and a manager that was briefly offline can never catch up — it has to be removed and re-added to the cluster."
      }
    ]
  end

  def locked_fields(_), do: []

  @doc """
  Reads the live cluster state.

  Returns `{:error, :not_in_swarm}` or `{:error, :not_a_manager}` rather than an
  HTTP error for the two states that are perfectly normal on a homelab host, so
  the settings page can say something useful instead of rendering a 503.
  """
  def load do
    case Client.get("/info") do
      {:ok, info} when is_map(info) -> load_with_info(info)
      {:error, reason} -> {:error, {:docker_unavailable, reason}}
    end
  end

  defp load_with_info(info) do
    swarm = Map.get(info, "Swarm") || %{}

    cond do
      Map.get(swarm, "LocalNodeState") != "active" ->
        {:error, :not_in_swarm}

      # Only managers may read or write the cluster spec; a worker gets a 503 from
      # the daemon. Say that plainly rather than surfacing an HTTP error the user
      # cannot act on from this machine.
      Map.get(swarm, "ControlAvailable") != true ->
        {:error, :not_a_manager}

      true ->
        read_swarm(info, swarm)
    end
  end

  defp read_swarm(info, swarm_info) do
    case Client.get("/swarm") do
      {:ok, %{"Spec" => spec} = cluster} when is_map(spec) ->
        {:ok,
         %{
           spec: spec,
           version: get_in(cluster, ["Version", "Index"]),
           values: to_form_values(spec),
           locked: locked_fields(spec),
           facts: facts(info, swarm_info, cluster)
         }}

      # /info said this node is an active manager, so a 503 here means the daemon
      # changed its mind between the two calls (demoted, or leaving the swarm).
      {:ok, _} ->
        {:error, :not_in_swarm}

      {:error, {:http_error, 503, _body}} ->
        {:error, :not_a_manager}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read-only cluster facts worth showing: who is in the cluster, and since when.
  """
  def facts(info, swarm_info, cluster) do
    %{
      swarm_id: Map.get(cluster, "ID"),
      name: get_in(cluster, ["Spec", "Name"]),
      labels: get_in(cluster, ["Spec", "Labels"]) || %{},
      created_at: Map.get(cluster, "CreatedAt"),
      updated_at: Map.get(cluster, "UpdatedAt"),
      version_index: get_in(cluster, ["Version", "Index"]),
      node_id: Map.get(swarm_info, "NodeID"),
      nodes: Map.get(swarm_info, "Nodes"),
      managers: Map.get(swarm_info, "Managers"),
      is_manager: Map.get(swarm_info, "ControlAvailable") == true,
      server_version: Map.get(info, "ServerVersion"),
      root_rotation_in_progress: Map.get(cluster, "RootRotationInProgress") == true
    }
  end

  @doc """
  Projects the raw spec onto the form's vocabulary: seconds and days, not the
  nanoseconds the API speaks.
  """
  def to_form_values(spec) when is_map(spec) do
    %{
      "task_history_retention_limit" =>
        get_in(spec, ["Orchestration", "TaskHistoryRetentionLimit"]) || @default_task_history,
      "dispatcher_heartbeat_seconds" =>
        ns_to(get_in(spec, ["Dispatcher", "HeartbeatPeriod"]), @ns_per_second) ||
          @default_heartbeat_seconds,
      "node_cert_expiry_days" =>
        ns_to(get_in(spec, ["CAConfig", "NodeCertExpiry"]), @ns_per_day) ||
          @default_cert_expiry_days
    }
  end

  def to_form_values(_), do: to_form_values(%{})

  defp ns_to(ns, divisor) when is_integer(ns) and ns > 0, do: div(ns, divisor)
  defp ns_to(_, _), do: nil

  @doc """
  Validates raw form params.

  Returns `{:ok, changes}` with integer values, or `{:error, errors}` where
  `errors` maps a field key to a sentence a human can act on. Every lever is
  bounded, because "I typed 100000 into a box" must not become a wedged cluster
  or a 500 page.
  """
  def validate(params) when is_map(params) do
    {changes, errors} =
      Enum.reduce(fields(), {%{}, %{}}, fn field, {changes, errors} ->
        case cast_int(Map.get(params, field.param), field) do
          {:ok, value} -> {Map.put(changes, field.key, value), errors}
          {:error, message} -> {changes, Map.put(errors, field.key, message)}
        end
      end)

    if errors == %{}, do: {:ok, changes}, else: {:error, errors}
  end

  defp cast_int(value, field) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {int, ""} -> bounds_check(int, field)
      # Reject "5 seconds" and "5.5" outright. Silently truncating a value the
      # user did not type is how a settings page loses someone's trust.
      _ -> {:error, "must be a whole number"}
    end
  end

  defp cast_int(value, field) when is_integer(value), do: bounds_check(value, field)
  defp cast_int(_, _), do: {:error, "is required"}

  defp bounds_check(int, field) do
    if int >= field.min and int <= field.max do
      {:ok, int}
    else
      {:error, "must be between #{field.min} and #{field.max} #{field.unit}"}
    end
  end

  @doc """
  Merges validated changes into a full spec.

  Deliberately a deep put onto the *given* spec rather than a fresh map: the
  daemon treats the posted spec as the complete new one, so anything dropped here
  (Raft tuning, auto-lock, task defaults, cluster labels) would be silently reset
  to Docker's default on the next save.
  """
  def merge_spec(spec, changes) when is_map(spec) and is_map(changes) do
    spec
    |> deep_put(
      ["Orchestration", "TaskHistoryRetentionLimit"],
      changes.task_history_retention_limit
    )
    |> deep_put(
      ["Dispatcher", "HeartbeatPeriod"],
      changes.dispatcher_heartbeat_seconds * @ns_per_second
    )
    |> deep_put(["CAConfig", "NodeCertExpiry"], changes.node_cert_expiry_days * @ns_per_day)
  end

  defp deep_put(map, [key], value), do: Map.put(map, key, value)

  defp deep_put(map, [key | rest], value) do
    child =
      case Map.get(map, key) do
        %{} = existing -> existing
        _ -> %{}
      end

    Map.put(map, key, deep_put(child, rest, value))
  end

  @doc """
  Validates, re-reads the current spec, merges, and posts the whole thing back.

  The rotation flags are pinned to false explicitly. They default to false today,
  but a save from a settings page must never rotate the worker/manager join tokens
  or the manager unlock key as a side effect — that would invalidate the join
  tokens every node in the cluster was given.
  """
  def update(params) do
    with {:ok, changes} <- validate(params),
         {:ok, state} <- load(),
         {:ok, version} <- require_version(state) do
      query =
        URI.encode_query(%{
          "version" => version,
          "rotateWorkerToken" => "false",
          "rotateManagerToken" => "false",
          "rotateManagerUnlockKey" => "false"
        })

      case Client.post("/swarm/update?" <> query, merge_spec(state.spec, changes)) do
        {:ok, _} -> load()
        {:error, reason} -> {:error, reason}
      end
    end
  end

  # No Version.Index means we cannot satisfy the daemon's optimistic-concurrency
  # check, and posting without one would be rejected anyway. Fail before the write.
  defp require_version(%{version: version}) when is_integer(version), do: {:ok, version}
  defp require_version(_), do: {:error, :missing_swarm_version}
end
