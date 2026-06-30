defmodule Homelab.InflectTest do
  use ExUnit.Case, async: true

  alias Homelab.Inflect

  describe "gerund/1 and past/1 for the app's action verbs" do
    # {root, gerund, past}
    cases = [
      {"Save", "Saving", "Saved"},
      {"Deploy", "Deploying", "Deployed"},
      {"Sync", "Syncing", "Synced"},
      {"Add", "Adding", "Added"},
      {"Create", "Creating", "Created"},
      {"Update", "Updating", "Updated"},
      {"Delete", "Deleting", "Deleted"},
      {"Remove", "Removing", "Removed"},
      {"Test", "Testing", "Tested"},
      {"Apply", "Applying", "Applied"},
      {"Verify", "Verifying", "Verified"},
      {"Confirm", "Confirming", "Confirmed"},
      {"Submit", "Submitting", "Submitted"},
      {"Install", "Installing", "Installed"},
      {"Start", "Starting", "Started"},
      {"Stop", "Stopping", "Stopped"},
      {"Restart", "Restarting", "Restarted"},
      {"Connect", "Connecting", "Connected"},
      {"Refresh", "Refreshing", "Refreshed"},
      {"Enable", "Enabling", "Enabled"},
      {"Disable", "Disabling", "Disabled"},
      {"Generate", "Generating", "Generated"},
      {"Reset", "Resetting", "Reset"},
      {"Import", "Importing", "Imported"},
      {"Export", "Exporting", "Exported"},
      {"Edit", "Editing", "Edited"},
      {"Send", "Sending", "Sent"},
      {"Build", "Building", "Built"},
      {"Run", "Running", "Ran"}
    ]

    for {root, gerund, past} <- cases do
      test "#{root} -> #{gerund} / #{past}" do
        assert Inflect.gerund(unquote(root)) == unquote(gerund)
        assert Inflect.past(unquote(root)) == unquote(past)
      end
    end
  end

  describe "verb-led phrases" do
    test "conjugates only the leading verb, preserving the remainder" do
      assert Inflect.gerund("Sync Registrar") == "Syncing Registrar"
      assert Inflect.past("Sync Registrar") == "Synced Registrar"
      assert Inflect.gerund("Add Zone") == "Adding Zone"
      assert Inflect.past("Add Zone") == "Added Zone"
    end
  end

  describe "capitalization" do
    test "preserves the original leading case" do
      assert Inflect.gerund("save") == "saving"
      assert Inflect.past("save") == "saved"
      assert Inflect.gerund("Save") == "Saving"
    end
  end
end
