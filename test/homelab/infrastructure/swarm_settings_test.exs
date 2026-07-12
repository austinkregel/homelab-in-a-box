defmodule Homelab.Infrastructure.SwarmSettingsTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Infrastructure.SwarmSettings

  setup :verify_on_exit!

  # A realistic `GET /swarm` body. The Raft/EncryptionConfig/TaskDefaults keys are
  # here on purpose: the whole point of merge_spec/2 is that they survive a save.
  defp swarm_body(overrides \\ %{}) do
    Map.merge(
      %{
        "ID" => "abc123swarmid",
        "CreatedAt" => "2024-03-01T10:00:00.000000000Z",
        "UpdatedAt" => "2024-06-01T12:30:00.000000000Z",
        "Version" => %{"Index" => 42},
        "RootRotationInProgress" => false,
        "Spec" => %{
          "Name" => "default",
          "Labels" => %{},
          "Orchestration" => %{"TaskHistoryRetentionLimit" => 5},
          "Raft" => %{
            "SnapshotInterval" => 10_000,
            "KeepOldSnapshots" => 0,
            "LogEntriesForSlowFollowers" => 500,
            "ElectionTick" => 10,
            "HeartbeatTick" => 1
          },
          "Dispatcher" => %{"HeartbeatPeriod" => 5_000_000_000},
          "CAConfig" => %{"NodeCertExpiry" => 7_776_000_000_000_000},
          "EncryptionConfig" => %{"AutoLockManagers" => true},
          "TaskDefaults" => %{"LogDriver" => %{"Name" => "json-file"}}
        }
      },
      overrides
    )
  end

  defp info_body(swarm_overrides \\ %{}) do
    %{
      "ServerVersion" => "26.1.4",
      "Swarm" =>
        Map.merge(
          %{
            "LocalNodeState" => "active",
            "ControlAvailable" => true,
            "NodeID" => "node-1",
            "Nodes" => 3,
            "Managers" => 1
          },
          swarm_overrides
        )
    }
  end

  defp use_mock_docker do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
  end

  describe "to_form_values/1" do
    test "converts the API's nanoseconds into the seconds and days a human types" do
      values = SwarmSettings.to_form_values(swarm_body()["Spec"])

      assert values["task_history_retention_limit"] == 5
      assert values["dispatcher_heartbeat_seconds"] == 5
      assert values["node_cert_expiry_days"] == 90
    end

    test "falls back to Docker's defaults when the spec omits a key" do
      values = SwarmSettings.to_form_values(%{})

      assert values["task_history_retention_limit"] == 5
      assert values["dispatcher_heartbeat_seconds"] == 5
      assert values["node_cert_expiry_days"] == 90
    end
  end

  describe "validate/1" do
    test "casts well-formed string params to integers" do
      params = %{
        "task_history_retention_limit" => "20",
        "dispatcher_heartbeat_seconds" => "10",
        "node_cert_expiry_days" => "30"
      }

      assert {:ok, changes} = SwarmSettings.validate(params)

      assert changes == %{
               task_history_retention_limit: 20,
               dispatcher_heartbeat_seconds: 10,
               node_cert_expiry_days: 30
             }
    end

    test "rejects a value above the allowed range with an actionable message" do
      params = %{
        "task_history_retention_limit" => "99999",
        "dispatcher_heartbeat_seconds" => "5",
        "node_cert_expiry_days" => "90"
      }

      assert {:error, errors} = SwarmSettings.validate(params)
      assert Map.keys(errors) == [:task_history_retention_limit]
      assert errors.task_history_retention_limit =~ "between 0 and 1000"
    end

    test "rejects a value below the allowed range" do
      params = %{
        "task_history_retention_limit" => "5",
        "dispatcher_heartbeat_seconds" => "0",
        "node_cert_expiry_days" => "90"
      }

      assert {:error, errors} = SwarmSettings.validate(params)
      assert errors.dispatcher_heartbeat_seconds =~ "between 1 and 60"
    end

    test "rejects non-numeric and fractional input rather than truncating it" do
      params = %{
        "task_history_retention_limit" => "lots",
        "dispatcher_heartbeat_seconds" => "5.5",
        "node_cert_expiry_days" => ""
      }

      assert {:error, errors} = SwarmSettings.validate(params)
      assert errors.task_history_retention_limit =~ "whole number"
      assert errors.dispatcher_heartbeat_seconds =~ "whole number"
      assert errors.node_cert_expiry_days =~ "whole number"
    end

    test "reports every bad field at once, not just the first" do
      params = %{
        "task_history_retention_limit" => "-1",
        "dispatcher_heartbeat_seconds" => "600",
        "node_cert_expiry_days" => "0"
      }

      assert {:error, errors} = SwarmSettings.validate(params)
      assert map_size(errors) == 3
    end
  end

  describe "merge_spec/2" do
    test "writes the editable leaves back in the API's nanosecond units" do
      changes = %{
        task_history_retention_limit: 25,
        dispatcher_heartbeat_seconds: 10,
        node_cert_expiry_days: 30
      }

      merged = SwarmSettings.merge_spec(swarm_body()["Spec"], changes)

      assert get_in(merged, ["Orchestration", "TaskHistoryRetentionLimit"]) == 25
      assert get_in(merged, ["Dispatcher", "HeartbeatPeriod"]) == 10_000_000_000
      assert get_in(merged, ["CAConfig", "NodeCertExpiry"]) == 30 * 86_400 * 1_000_000_000
    end

    test "preserves every field it does not own" do
      # This is the bug the module exists to prevent: POST /swarm/update replaces the
      # whole spec, so a merge that dropped these would turn auto-lock off and reset
      # Raft tuning behind the user's back.
      spec = swarm_body()["Spec"]

      merged =
        SwarmSettings.merge_spec(spec, %{
          task_history_retention_limit: 25,
          dispatcher_heartbeat_seconds: 10,
          node_cert_expiry_days: 30
        })

      assert get_in(merged, ["EncryptionConfig", "AutoLockManagers"]) == true
      assert merged["Raft"] == spec["Raft"]
      assert merged["TaskDefaults"] == spec["TaskDefaults"]
      assert merged["Name"] == "default"
      assert merged["Labels"] == %{}
    end

    test "creates a missing sub-map instead of crashing on an older daemon's spec" do
      merged =
        SwarmSettings.merge_spec(%{"Name" => "default"}, %{
          task_history_retention_limit: 5,
          dispatcher_heartbeat_seconds: 5,
          node_cert_expiry_days: 90
        })

      assert get_in(merged, ["Orchestration", "TaskHistoryRetentionLimit"]) == 5
      assert merged["Name"] == "default"
    end
  end

  describe "locked_fields/1" do
    test "surfaces auto-lock and the Raft knobs read-only, each with a reason" do
      locked = SwarmSettings.locked_fields(swarm_body()["Spec"])

      labels = Enum.map(locked, & &1.label)
      assert "Auto-lock managers" in labels
      assert "Raft election tick" in labels

      autolock = Enum.find(locked, &(&1.label == "Auto-lock managers"))
      assert autolock.value == "On"
      assert autolock.why =~ "unrecoverable"

      # Every locked field must explain itself — that is the entire point of showing them.
      assert Enum.all?(locked, &(String.length(&1.why) > 40))
    end
  end

  describe "load/0" do
    test "returns spec, version, values and cluster facts for a manager node" do
      use_mock_docker()

      Homelab.Mocks.DockerClient
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ -> {:ok, swarm_body()} end)

      assert {:ok, state} = SwarmSettings.load()

      assert state.version == 42
      assert state.values["task_history_retention_limit"] == 5
      assert state.facts.nodes == 3
      assert state.facts.managers == 1
      assert state.facts.is_manager
      assert state.facts.swarm_id == "abc123swarmid"
      assert state.facts.server_version == "26.1.4"
    end

    test "returns :not_in_swarm when the daemon has not joined a swarm" do
      use_mock_docker()

      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _ ->
        {:ok, info_body(%{"LocalNodeState" => "inactive", "ControlAvailable" => false})}
      end)

      assert {:error, :not_in_swarm} = SwarmSettings.load()
    end

    test "returns :not_a_manager on a worker node, without ever calling /swarm" do
      use_mock_docker()

      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _ ->
        {:ok, info_body(%{"ControlAvailable" => false})}
      end)

      assert {:error, :not_a_manager} = SwarmSettings.load()
    end

    test "returns :not_a_manager when /swarm answers 503 despite what /info said" do
      use_mock_docker()

      Homelab.Mocks.DockerClient
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ ->
        {:error, {:http_error, 503, %{"message" => "This node is not a swarm manager."}}}
      end)

      assert {:error, :not_a_manager} = SwarmSettings.load()
    end

    test "reports an unreachable daemon rather than crashing the page" do
      use_mock_docker()

      expect(Homelab.Mocks.DockerClient, :get, fn "/info", _ ->
        {:error, {:connection_error, :econnrefused}}
      end)

      assert {:error, {:docker_unavailable, {:connection_error, :econnrefused}}} =
               SwarmSettings.load()
    end
  end

  describe "update/1" do
    test "posts the FULL merged spec with the current version as the ?version= param" do
      use_mock_docker()

      Homelab.Mocks.DockerClient
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ -> {:ok, swarm_body()} end)
      |> expect(:post, fn path, body, _ ->
        assert path =~ "/swarm/update?"
        assert path =~ "version=42"

        # Rotation flags must be pinned off: a settings save that rotated the join
        # tokens would invalidate the token every node in the cluster was given.
        assert path =~ "rotateWorkerToken=false"
        assert path =~ "rotateManagerToken=false"
        assert path =~ "rotateManagerUnlockKey=false"

        assert get_in(body, ["Orchestration", "TaskHistoryRetentionLimit"]) == 50
        assert get_in(body, ["Dispatcher", "HeartbeatPeriod"]) == 8_000_000_000
        # Untouched fields are still present — a partial spec would wipe them.
        assert get_in(body, ["EncryptionConfig", "AutoLockManagers"]) == true
        assert get_in(body, ["Raft", "ElectionTick"]) == 10

        {:ok, %{}}
      end)
      # update/1 re-reads after the write so the form shows what the daemon accepted.
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ ->
        {:ok,
         swarm_body(%{
           "Version" => %{"Index" => 43},
           "Spec" =>
             put_in(
               swarm_body()["Spec"],
               ["Orchestration", "TaskHistoryRetentionLimit"],
               50
             )
         })}
      end)

      params = %{
        "task_history_retention_limit" => "50",
        "dispatcher_heartbeat_seconds" => "8",
        "node_cert_expiry_days" => "90"
      }

      assert {:ok, state} = SwarmSettings.update(params)
      assert state.values["task_history_retention_limit"] == 50
      assert state.version == 43
    end

    test "does not touch Docker at all when the input is invalid" do
      use_mock_docker()

      # No expectations set: any call to the daemon fails the test. Validation must
      # happen before the read-modify-write cycle starts.
      assert {:error, errors} =
               SwarmSettings.update(%{
                 "task_history_retention_limit" => "-5",
                 "dispatcher_heartbeat_seconds" => "5",
                 "node_cert_expiry_days" => "90"
               })

      assert Map.has_key?(errors, :task_history_retention_limit)
    end

    test "surfaces a stale-version rejection from the daemon" do
      use_mock_docker()

      Homelab.Mocks.DockerClient
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ -> {:ok, swarm_body()} end)
      |> expect(:post, fn _, _, _ ->
        {:error, {:http_error, 500, %{"message" => "update out of sequence"}}}
      end)

      assert {:error, {:http_error, 500, _}} =
               SwarmSettings.update(%{
                 "task_history_retention_limit" => "5",
                 "dispatcher_heartbeat_seconds" => "5",
                 "node_cert_expiry_days" => "90"
               })
    end

    test "refuses to write when the daemon reports no spec version" do
      use_mock_docker()

      Homelab.Mocks.DockerClient
      |> expect(:get, fn "/info", _ -> {:ok, info_body()} end)
      |> expect(:get, fn "/swarm", _ -> {:ok, swarm_body(%{"Version" => %{}})} end)

      assert {:error, :missing_swarm_version} =
               SwarmSettings.update(%{
                 "task_history_retention_limit" => "5",
                 "dispatcher_heartbeat_seconds" => "5",
                 "node_cert_expiry_days" => "90"
               })
    end
  end
end
