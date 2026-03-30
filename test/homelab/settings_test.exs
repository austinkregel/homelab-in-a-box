defmodule Homelab.SettingsTest do
  use Homelab.DataCase, async: false

  alias Homelab.Settings

  setup do
    Settings.init_cache()
    :ok
  end

  describe "get/2 and set/3" do
    test "stores and retrieves a setting" do
      assert {:ok, _} = Settings.set("test_key", "test_value")
      assert Settings.get("test_key") == "test_value"
    end

    test "returns default when setting does not exist" do
      assert Settings.get("nonexistent", "default") == "default"
    end

    test "returns nil by default when setting does not exist" do
      assert Settings.get("nonexistent") == nil
    end

    test "overwrites existing setting" do
      Settings.set("overwrite_key", "v1")
      Settings.set("overwrite_key", "v2")
      assert Settings.get("overwrite_key") == "v2"
    end
  end

  describe "get!/1" do
    test "returns the value when setting exists" do
      Settings.set("existing", "value")
      assert Settings.get!("existing") == "value"
    end

    test "raises when setting does not exist" do
      assert_raise RuntimeError, ~r/not found/, fn ->
        Settings.get!("nonexistent_key_#{System.unique_integer()}")
      end
    end
  end

  describe "encrypted settings" do
    test "stores and retrieves encrypted values" do
      {:ok, _} = Settings.set("secret", "my-secret-value", encrypt: true)
      assert Settings.get("secret") == "my-secret-value"
    end
  end

  describe "delete/1" do
    test "removes a setting" do
      Settings.set("deletable", "value")
      assert Settings.get("deletable") == "value"
      assert :ok = Settings.delete("deletable")
      assert Settings.get("deletable") == nil
    end

    test "is idempotent for nonexistent keys" do
      assert :ok = Settings.delete("never_existed")
    end
  end

  describe "all_by_category/1" do
    test "returns settings grouped by category" do
      Settings.set("cat_a", "1", category: "alpha")
      Settings.set("cat_b", "2", category: "alpha")
      Settings.set("cat_c", "3", category: "beta")

      alpha = Settings.all_by_category("alpha")
      assert alpha["cat_a"] == "1"
      assert alpha["cat_b"] == "2"
      refute Map.has_key?(alpha, "cat_c")
    end
  end

  describe "setup_completed?/0 and mark_setup_completed/0" do
    test "returns false when setup not completed" do
      refute Settings.setup_completed?()
    end

    test "returns true after marking complete" do
      Settings.mark_setup_completed()
      assert Settings.setup_completed?()
    end
  end

  describe "cache invalidation via PubSub" do
    test "broadcasts on setting change" do
      Settings.subscribe()
      Settings.set("pubsub_key", "value")
      assert_receive {:setting_changed, "pubsub_key"}
    end
  end
end
