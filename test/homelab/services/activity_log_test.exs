defmodule Homelab.Services.ActivityLogTest do
  use Homelab.DataCase, async: false

  alias Homelab.Services.ActivityLog

  describe "push/4" do
    test "adds an event and returns it" do
      event = ActivityLog.push(:info, "test", "Hello")
      assert event.level == :info
      assert event.source == "test"
      assert event.message == "Hello"
      assert %DateTime{} = event.timestamp
    end

    test "broadcasts event via PubSub" do
      Phoenix.PubSub.subscribe(Homelab.PubSub, ActivityLog.topic())
      ActivityLog.push(:info, "test", "Broadcast test")
      assert_receive {:activity_event, event}
      assert event.message == "Broadcast test"
    end

    test "accepts metadata" do
      event = ActivityLog.push(:info, "test", "With meta", %{key: "value"})
      assert event.metadata == %{key: "value"}
    end
  end

  describe "recent/1" do
    test "returns most recent events" do
      for i <- 1..5, do: ActivityLog.push(:info, "test", "Event #{i}")
      recent = ActivityLog.recent(3)
      assert length(recent) == 3
    end
  end

  describe "all/0" do
    test "returns all stored events" do
      for i <- 1..3, do: ActivityLog.push(:info, "test", "Event #{i}")
      assert length(ActivityLog.all()) >= 3
    end
  end

  describe "convenience functions" do
    test "info/3 pushes an info event" do
      event = ActivityLog.info("source", "info msg")
      assert event.level == :info
    end

    test "warn/3 pushes a warn event" do
      event = ActivityLog.warn("source", "warn msg")
      assert event.level == :warn
    end

    test "error/3 pushes an error event" do
      event = ActivityLog.error("source", "error msg")
      assert event.level == :error
    end
  end

  describe "topic/0" do
    test "returns the PubSub topic" do
      assert ActivityLog.topic() == "activity:feed"
    end
  end
end
