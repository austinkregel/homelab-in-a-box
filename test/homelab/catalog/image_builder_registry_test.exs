defmodule Homelab.Catalog.ImageBuilderRegistryTest do
  # async: false — mutates :homelab application env (registry config).
  use ExUnit.Case, async: false

  import Mox

  alias Homelab.Catalog.ImageBuilder

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)

    prev = %{
      base_domain: Application.get_env(:homelab, :base_domain),
      enabled: Application.get_env(:homelab, :registry_enabled),
      creds: Application.get_env(:homelab, :registry_credentials)
    }

    Application.put_env(:homelab, :base_domain, "example.com")
    # Default disabled so registry_configured? short-circuits without touching
    # Settings (this test module has no DB sandbox).
    Application.put_env(:homelab, :registry_enabled, false)

    on_exit(fn ->
      restore(:base_domain, prev.base_domain)
      restore(:registry_enabled, prev.enabled)
      restore(:registry_credentials, prev.creds)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, val), do: Application.put_env(:homelab, key, val)

  defp files, do: [%{name: "Dockerfile", content: "FROM alpine:latest\n"}]

  describe "build/3 with registry configured" do
    setup do
      Application.put_env(:homelab, :registry_enabled, true)
      Application.put_env(:homelab, :registry_credentials, {"bob", "s3cret"})
      :ok
    end

    test "retags and pushes the built image, returning the registry ref" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :build, fn _q, _c, _on_event -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        send(test_pid, {:tag, path})
        {:ok, %{}}
      end)

      expect(Homelab.Mocks.DockerClient, :push, fn image, opts ->
        send(test_pid, {:push, image, opts})
        :ok
      end)

      assert {:ok, ref} =
               ImageBuilder.build(files(), [tag: "homelab-built/app:1.0"], fn _ -> :ok end)

      assert ref == "registry.example.com/homelab-built/app:1.0"
      assert_received {:tag, tag_path}
      assert String.starts_with?(tag_path, "/images/homelab-built/app:1.0/tag")
      assert tag_path =~ "repo=registry.example.com/homelab-built/app"
      assert tag_path =~ "tag=1.0"

      assert_received {:push, "registry.example.com/homelab-built/app:1.0", push_opts}
      assert Enum.any?(Keyword.get(push_opts, :headers, []), &match?({"X-Registry-Auth", _}, &1))
    end
  end

  describe "build/3 without registry configured" do
    test "returns the local ref and never pushes" do
      stub(Homelab.Mocks.DockerClient, :build, fn _q, _c, _on_event -> :ok end)

      stub(Homelab.Mocks.DockerClient, :push, fn _image, _opts ->
        flunk("must not push when the registry is not configured")
      end)

      assert {:ok, "homelab-built/app:1.0"} =
               ImageBuilder.build(files(), [tag: "homelab-built/app:1.0"], fn _ -> :ok end)
    end
  end
end
