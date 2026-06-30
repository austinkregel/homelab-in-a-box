defmodule Homelab.Deployments.Migrate.ContainerCopyEngineTest do
  use ExUnit.Case, async: true

  import Mox

  alias Homelab.Deployments.Migrate.ContainerCopyEngine, as: Engine

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  # A RESULT log line that parse_result/1 turns into a verified proof.
  @result_log "RESULT files=12 kbytes=2048 digest=deadbeef\r\n"

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

  describe "migrate/2 (mocked daemon)" do
    # GETs route image-inspect vs logs by path; POSTs route create/start/wait.
    defp stub_get(opts) do
      logs = Keyword.get(opts, :logs, @result_log)
      image = Keyword.get(opts, :image, {:ok, %{"Id" => "img"}})

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        cond do
          String.starts_with?(path, "/images/") and String.ends_with?(path, "/json") ->
            image

          String.contains?(path, "/logs") ->
            {:ok, logs}
        end
      end)
    end

    defp stub_post(opts) do
      wait = Keyword.get(opts, :wait, {:ok, %{"StatusCode" => 0}})

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        cond do
          path == "/containers/create" ->
            assert body["Image"] == "alpine:3.20"
            assert body["Cmd"] == ["/bin/sh", "-c", Engine.build_script()]
            assert body["HostConfig"]["Binds"] == Engine.binds("/data/src", "/data/dest")
            {:ok, %{"Id" => "helper-1"}}

          String.ends_with?(path, "/start") ->
            {:ok, %{}}

          String.ends_with?(path, "/wait") ->
            assert is_nil(body)
            wait
        end
      end)
    end

    test "happy path: existing image, create/start/wait/logs, exit 0 -> verified proof, helper removed" do
      stub_get([])
      stub_post([])
      remove_collector()

      assert {:ok, proof} = Engine.migrate("/data/src", "/data/dest")
      assert proof["files"] == 12
      assert proof["bytes"] == 2048 * 1024
      assert proof["digest"] == "deadbeef"
      assert proof["verified"] == true

      assert_received {:removed, "/containers/helper-1?force=true"}
      refute_received {:removed, _}
    end

    test "missing image (404) triggers a streaming pull before create" do
      test_pid = self()

      stub_get(image: {:error, {:not_found, %{}}})
      stub_post([])
      remove_collector()

      expect(Homelab.Mocks.DockerClient, :post_stream, fn path, _opts ->
        send(test_pid, {:pulled, path})
        :ok
      end)

      assert {:ok, _proof} = Engine.migrate("/data/src", "/data/dest")
      assert_received {:pulled, "/images/create?fromImage=alpine&tag=3.20"}
      assert_received {:removed, "/containers/helper-1?force=true"}
    end

    test "exit 3 -> verify mismatch, and helper is still removed" do
      stub_get(logs: "VERIFY_MISMATCH\r\n")
      stub_post(wait: {:ok, %{"StatusCode" => 3}})
      remove_collector()

      assert {:error, {:verify_mismatch, :container}} = Engine.migrate("/data/src", "/data/dest")
      assert_received {:removed, "/containers/helper-1?force=true"}
    end

    test "other non-zero exit -> helper_failed, and helper is still removed" do
      stub_get(logs: "boom: something broke\r\n")
      stub_post(wait: {:ok, %{"StatusCode" => 137}})
      remove_collector()

      assert {:error, {:helper_failed, 137, log}} = Engine.migrate("/data/src", "/data/dest")
      assert log =~ "boom"
      assert_received {:removed, "/containers/helper-1?force=true"}
    end

    test "exit 0 but no RESULT line -> helper_no_result, and helper is still removed" do
      stub_get(logs: "no result here\r\n")
      stub_post(wait: {:ok, %{"StatusCode" => 0}})
      remove_collector()

      assert {:error, {:helper_no_result, "no result here\r\n"}} =
               Engine.migrate("/data/src", "/data/dest")

      assert_received {:removed, "/containers/helper-1?force=true"}
    end

    test "a create failure short-circuits (no start, no remove, no wait)" do
      stub_get([])

      expect(Homelab.Mocks.DockerClient, :post, fn "/containers/create", _body, _opts ->
        {:error, {:http_error, 500, %{}}}
      end)

      # No delete should occur because create failed before an id existed.
      assert {:error, {:create_failed, {:http_error, 500, %{}}}} =
               Engine.migrate("/data/src", "/data/dest")
    end

    test "an image-inspect error (non-404) aborts before create" do
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts ->
        {:error, {:connection_error, :nope}}
      end)

      assert {:error, {:image_inspect_failed, {:connection_error, :nope}}} =
               Engine.migrate("/data/src", "/data/dest")
    end

    # Records every DELETE (helper removal) as a message to the test process so we
    # can assert the helper is *always* torn down, even on the failure branches.
    defp remove_collector do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        send(test_pid, {:removed, path})
        {:ok, %{}}
      end)
    end
  end
end
