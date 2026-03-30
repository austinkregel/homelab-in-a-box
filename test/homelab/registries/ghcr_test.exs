defmodule Homelab.Registries.GHCRTest do
  use Homelab.DataCase, async: false

  alias Homelab.Registries.GHCR
  alias Homelab.TestFixtures.ApiServer

  describe "driver metadata" do
    test "returns driver_id" do
      assert GHCR.driver_id() == "ghcr"
    end

    test "returns display_name" do
      assert GHCR.display_name() == "GitHub (GHCR)"
    end
  end

  describe "search/2" do
    test "returns packages from org or user" do
      bypass = Bypass.open()
      base_url = ApiServer.ghcr(bypass)
      Application.put_env(:homelab, GHCR, base_url: base_url)
      on_exit(fn -> Application.delete_env(:homelab, GHCR) end)

      {:ok, entries} = GHCR.search("myorg")
      assert length(entries) > 0
      assert hd(entries).name == "myapp"
    end
  end

  describe "list_tags/2" do
    test "returns tags for a package" do
      bypass = Bypass.open()
      base_url = ApiServer.ghcr(bypass)
      Application.put_env(:homelab, GHCR, base_url: base_url)
      on_exit(fn -> Application.delete_env(:homelab, GHCR) end)

      {:ok, tags} = GHCR.list_tags("myorg/myapp")
      assert length(tags) > 0
    end

    test "returns error for invalid image format" do
      assert {:error, :invalid_image} = GHCR.list_tags("no-slash")
    end
  end

  describe "full_image_ref/2" do
    test "constructs GHCR image reference" do
      assert GHCR.full_image_ref("myorg/myapp", "v1") == "ghcr.io/myorg/myapp:v1"
    end
  end

  describe "configured?/0" do
    test "returns false when ghcr_token is not set" do
      Homelab.Settings.init_cache()
      refute GHCR.configured?()
    end

    test "returns true when ghcr_token is set" do
      Homelab.Settings.init_cache()
      Homelab.Settings.set("ghcr_token", "test-token")
      assert GHCR.configured?()
    end
  end
end
