defmodule Homelab.ContainerIdTest do
  use ExUnit.Case, async: true

  alias Homelab.ContainerId

  describe "hostname?/1" do
    test "accepts short (12) and full (64) lowercase hex IDs" do
      assert ContainerId.hostname?("a1b2c3d4e5f6")
      assert ContainerId.hostname?(String.duplicate("a", 64))
    end

    test "rejects human hostnames, wrong length, and uppercase hex" do
      refute ContainerId.hostname?("kratos")
      refute ContainerId.hostname?("a1b2c3")
      refute ContainerId.hostname?("A1B2C3D4E5F6")
      refute ContainerId.hostname?("a1b2c3d4e5f6-not-an-id")
    end

    test "treats a missing hostname (nil / non-binary) as not a container ID" do
      refute ContainerId.hostname?(nil)
      refute ContainerId.hostname?(:undefined)
    end
  end
end
