defmodule Homelab.Catalog.ImageBuilderTest do
  # DataCase: build/3 now consults Config.registry_configured? (Settings/DB).
  use Homelab.DataCase, async: true

  import Mox

  alias Homelab.Catalog.ImageBuilder

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  defp dockerfile(content \\ "FROM alpine:latest\n") do
    %{name: "Dockerfile", content: content}
  end

  describe "build/3" do
    test "packs the context, tags the image, and streams events" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :build, fn query, context, on_event ->
        send(test_pid, {:build, query, context})
        on_event.(%{"stream" => "Step 1/1 : FROM alpine:latest\n"})
        :ok
      end)

      files = [dockerfile(), %{name: "app.sh", content: "echo hi\n"}]

      assert {:ok, "homelab-built/my-app:latest"} =
               ImageBuilder.build(files, [tag: "homelab-built/my-app:latest"], fn ev ->
                 send(test_pid, {:event, ev})
               end)

      assert_received {:build, query, context}
      assert query =~ "t=homelab-built/my-app:latest"
      assert query =~ "dockerfile=Dockerfile"
      # The build context is a non-empty gzip tarball (magic bytes 0x1f 0x8b).
      assert <<0x1F, 0x8B, _::binary>> = context
      # The streamed build event reached the caller's handler.
      assert_received {:event, %{"stream" => _}}
    end

    test "copies %{name:, path:} entries into the context alongside text files" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :build, fn _query, context, _on_event ->
        send(test_pid, {:context, context})
        :ok
      end)

      # A file already on disk (e.g. a Workbench upload) referenced by path.
      src = Path.join(System.tmp_dir!(), "ib-src-#{System.unique_integer([:positive])}.bin")
      File.write!(src, "binary-ish payload")
      on_exit(fn -> File.rm(src) end)

      files = [dockerfile(), %{name: "payload.bin", path: src}]

      assert {:ok, "homelab-built/mixed:latest"} =
               ImageBuilder.build(files, [tag: "homelab-built/mixed:latest"], fn _ -> :ok end)

      # The tar was produced (gzip magic) — the path entry was staged without error.
      assert_received {:context, <<0x1F, 0x8B, _::binary>>}
    end

    test "propagates a daemon build failure" do
      stub(Homelab.Mocks.DockerClient, :build, fn _q, _c, _f ->
        {:error, {:build_failed, "no such file"}}
      end)

      assert {:error, {:build_failed, "no such file"}} =
               ImageBuilder.build([dockerfile()], [tag: "homelab-built/x:latest"], fn _ -> :ok end)
    end

    test "returns an error when no Dockerfile is present" do
      files = [%{name: "app.sh", content: "echo hi\n"}]

      assert {:error, :missing_dockerfile} =
               ImageBuilder.build(files, [tag: "homelab-built/x:latest"], fn _ -> :ok end)
    end
  end
end
