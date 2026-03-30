defmodule Homelab.Registries.ECRTest do
  use ExUnit.Case, async: false

  alias Homelab.Registries.ECR
  alias Homelab.TestFixtures.ApiServer

  setup do
    bypass = Bypass.open()
    base_url = ApiServer.ecr(bypass)

    Application.put_env(:homelab, ECR, base_url: base_url)
    on_exit(fn -> Application.delete_env(:homelab, ECR) end)

    {:ok, bypass: bypass}
  end

  describe "driver metadata" do
    test "returns driver_id" do
      assert ECR.driver_id() == "ecr"
    end

    test "returns display_name" do
      assert ECR.display_name() == "AWS ECR Public"
    end
  end

  describe "search/2" do
    test "returns matching repositories" do
      {:ok, entries} = ECR.search("nginx")
      assert length(entries) > 0
      assert hd(entries).source == "ecr"
    end
  end

  describe "list_tags/2" do
    test "returns tags for a repository" do
      {:ok, tags} = ECR.list_tags("nginx")
      assert length(tags) > 0
      assert hd(tags).tag == "latest"
    end
  end

  describe "full_image_ref/2" do
    test "constructs ECR image reference" do
      assert ECR.full_image_ref("nginx", "latest") == "public.ecr.aws/nginx:latest"
    end
  end
end
