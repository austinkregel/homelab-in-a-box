defmodule Homelab.AuditTest do
  use Homelab.DataCase, async: true

  alias Homelab.Audit
  import Homelab.Factory

  describe "log/4" do
    test "creates an activity log entry" do
      assert {:ok, log} = Audit.log("deployment.created", "deployment", 1)
      assert log.action == "deployment.created"
      assert log.resource_type == "deployment"
      assert log.resource_id == 1
    end

    test "creates entry without resource_id" do
      assert {:ok, log} = Audit.log("system.boot", "system")
      assert log.resource_id == nil
    end

    test "attaches user_id when provided" do
      user = insert(:user)
      assert {:ok, log} = Audit.log("user.login", "user", user.id, user_id: user.id)
      assert log.user_id == user.id
    end

    test "stores metadata" do
      metadata = %{"ip" => "127.0.0.1", "action" => "login"}
      assert {:ok, log} = Audit.log("user.login", "user", nil, metadata: metadata)
      assert log.metadata == metadata
    end
  end

  describe "list_recent/1" do
    test "returns logs ordered by most recent first" do
      Audit.log("first", "test")
      Audit.log("second", "test")
      Audit.log("third", "test")

      logs = Audit.list_recent()
      actions = Enum.map(logs, & &1.action)
      assert ["third", "second", "first"] == actions
    end

    test "respects the limit parameter" do
      for i <- 1..5, do: Audit.log("action_#{i}", "test")
      assert length(Audit.list_recent(2)) == 2
    end

    test "preloads user association" do
      user = insert(:user)
      Audit.log("with_user", "test", nil, user_id: user.id)

      [log] = Audit.list_recent(1)
      assert log.user.email == user.email
    end
  end

  describe "list_for_resource/2" do
    test "returns logs for a specific resource" do
      Audit.log("deploy.start", "deployment", 42)
      Audit.log("deploy.done", "deployment", 42)
      Audit.log("other.action", "tenant", 99)

      logs = Audit.list_for_resource("deployment", 42)
      assert length(logs) == 2
      assert Enum.all?(logs, &(&1.resource_type == "deployment"))
    end
  end
end
