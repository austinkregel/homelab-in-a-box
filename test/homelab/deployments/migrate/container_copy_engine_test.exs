defmodule Homelab.Deployments.Migrate.ContainerCopyEngineTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Migrate.ContainerCopyEngine, as: Engine

  describe "binds/2" do
    test "mounts source read-only and dest writable" do
      assert Engine.binds("/data/pg", "/home/managed/pg/d") ==
               ["/data/pg:/src:ro", "/home/managed/pg/d:/dest"]
    end
  end

  describe "build_script/0" do
    test "preserves ownership and verifies inside the container" do
      script = Engine.build_script()
      assert script =~ "cp -a /src/. /dest/"
      assert script =~ "sha256sum"
      assert script =~ "diff /tmp/s /tmp/d"
      assert script =~ "exit 3"
      assert script =~ "RESULT files="
    end
  end

  describe "parse_result/1" do
    test "extracts files, bytes, and digest from the RESULT line" do
      log = "some noise\r\nRESULT files=42 kbytes=2048 digest=abc123def\r\n"

      assert {:ok, proof} = Engine.parse_result(log)
      assert proof["files"] == 42
      assert proof["kbytes"] == 2048
      assert proof["bytes"] == 2048 * 1024
      assert proof["digest"] == "abc123def"
      assert proof["verified"] == true
    end

    test "returns :error when there is no RESULT line" do
      assert :error = Engine.parse_result("VERIFY_MISMATCH\r\n")
    end
  end
end
