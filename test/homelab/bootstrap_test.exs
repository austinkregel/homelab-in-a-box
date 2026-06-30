defmodule Homelab.BootstrapTest do
  use Homelab.DataCase, async: false

  import Mox

  alias Homelab.Bootstrap

  setup :verify_on_exit!

  # Route this process's Docker client to the mock (no global state mutated).
  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "ensure_infrastructure/0" do
    test "is a no-op when bootstrap is disabled" do
      Application.put_env(:homelab, :bootstrap, false)
      on_exit(fn -> Application.delete_env(:homelab, :bootstrap) end)

      assert :ok = Bootstrap.ensure_infrastructure()
    end

    test "does not touch the Docker client when bootstrap is disabled (mocked daemon)" do
      Application.put_env(:homelab, :bootstrap, false)
      on_exit(fn -> Application.delete_env(:homelab, :bootstrap) end)

      # No `expect`/`stub` on the mock: verify_on_exit! confirms the gate
      # short-circuits before any Docker provisioning request is issued.
      assert :ok = Bootstrap.ensure_infrastructure()
    end
  end

  describe "maybe_seed_from_env/0" do
    test "does nothing when HOMELAB_SEED_SETUP is not set" do
      System.delete_env("HOMELAB_SEED_SETUP")
      assert Bootstrap.maybe_seed_from_env() in [:ok, nil]
    end

    test "seeds settings from environment variables" do
      Homelab.Settings.init_cache()
      System.put_env("HOMELAB_SEED_SETUP", "true")
      System.put_env("HOMELAB_INSTANCE_NAME", "TestLab")
      System.put_env("HOMELAB_BASE_DOMAIN", "test.local")

      on_exit(fn ->
        System.delete_env("HOMELAB_SEED_SETUP")
        System.delete_env("HOMELAB_INSTANCE_NAME")
        System.delete_env("HOMELAB_BASE_DOMAIN")
      end)

      Bootstrap.maybe_seed_from_env()

      assert Homelab.Settings.get("instance_name") == "TestLab"
      assert Homelab.Settings.get("base_domain") == "test.local"
      assert Homelab.Settings.setup_completed?()
    end

    test "skips seeding when setup is already completed" do
      Homelab.Settings.init_cache()
      Homelab.Settings.mark_setup_completed()
      System.put_env("HOMELAB_SEED_SETUP", "true")
      System.put_env("HOMELAB_INSTANCE_NAME", "ShouldNotAppear")

      on_exit(fn ->
        System.delete_env("HOMELAB_SEED_SETUP")
        System.delete_env("HOMELAB_INSTANCE_NAME")
      end)

      Bootstrap.maybe_seed_from_env()

      refute Homelab.Settings.get("instance_name") == "ShouldNotAppear"
    end
  end
end
