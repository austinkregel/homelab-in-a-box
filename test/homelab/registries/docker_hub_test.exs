defmodule Homelab.Registries.DockerHubTest do
  use ExUnit.Case, async: false

  alias Homelab.Registries.DockerHub
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.docker_hub(bypass)

    Application.put_env(:homelab, DockerHub, base_url: "#{base_url}/v2")
    on_exit(fn -> Application.delete_env(:homelab, DockerHub) end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert DockerHub.driver_id() == "dockerhub"
    end

    test "returns display_name" do
      assert DockerHub.display_name() == "Docker Hub"
    end

    test "returns capabilities" do
      assert :search in DockerHub.capabilities()
      assert :list_tags in DockerHub.capabilities()
    end
  end

  describe "search/2" do
    test "returns matching entries" do
      {:ok, entries} = DockerHub.search("nginx")
      assert length(entries) > 0
      assert hd(entries).source == "dockerhub"
    end

    test "handles empty results" do
      bypass = Bypass.open()

      Bypass.expect(bypass, fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(%{"results" => []}))
      end)

      Application.put_env(:homelab, DockerHub, base_url: "http://localhost:#{bypass.port}/v2")

      {:ok, entries} = DockerHub.search("nonexistent")
      assert entries == []
    end
  end

  describe "list_tags/2" do
    test "returns tags for an image" do
      {:ok, tags} = DockerHub.list_tags("library/nginx")
      assert length(tags) > 0
      assert hd(tags).tag == "latest"
    end
  end

  describe "full_image_ref/2" do
    test "constructs image reference" do
      assert DockerHub.full_image_ref("nginx", "latest") == "nginx:latest"
      assert DockerHub.full_image_ref("myorg/myapp", "v1") == "myorg/myapp:v1"
    end
  end
end
