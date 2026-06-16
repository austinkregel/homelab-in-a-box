defmodule Homelab.StorageTest do
  use ExUnit.Case, async: true

  test "available? is false without host agent socket" do
    refute Homelab.Storage.available?()
    assert is_binary(Homelab.Storage.unavailable_reason())
  end
end
