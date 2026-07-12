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

  describe "ensure_infrastructure/0 provisioning (mocked daemon)" do
    setup do
      original_repo = Application.get_env(:homelab, Homelab.Repo)
      original_oban = Application.get_env(:homelab, Homelab.ObanRepo)
      original_hostname = System.get_env("HOSTNAME")
      # Ensure own-container detection returns nil so no network-join call is made.
      System.delete_env("HOSTNAME")

      {:ok, listen} = :gen_tcp.listen(0, [:binary, active: false])
      {:ok, port} = :inet.port(listen)

      Application.put_env(:homelab, :bootstrap, true)
      Application.put_env(:homelab, :bootstrap_wait, attempts: 30, interval_ms: 0)
      Application.put_env(:homelab, :bootstrap_tcp_target, {~c"localhost", port})

      on_exit(fn ->
        Application.put_env(:homelab, Homelab.Repo, original_repo)
        Application.put_env(:homelab, Homelab.ObanRepo, original_oban)
        if original_hostname, do: System.put_env("HOSTNAME", original_hostname)
        Application.delete_env(:homelab, :bootstrap)
        Application.delete_env(:homelab, :bootstrap_wait)
        Application.delete_env(:homelab, :bootstrap_tcp_target)
        :gen_tcp.close(listen)
      end)

      :ok
    end

    test "when everything already exists, returns :ok and configures the repo hostname" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/networks/homelab-iab-internal", _ ->
          {:ok, %{"Containers" => %{}}}

        "/volumes/" <> _, _ ->
          {:ok, %{}}

        "/containers/" <> _, _ ->
          {:ok, %{"State" => %{"Running" => true, "Health" => %{"Status" => "healthy"}}}}
      end)

      assert :ok = Bootstrap.ensure_infrastructure()
      assert Application.get_env(:homelab, Homelab.Repo)[:hostname] == "homelab-iab-postgres"
    end

    test "creates network, volumes, and the Postgres container when missing" do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _ -> {:ok, %{"Swarm" => %{"LocalNodeState" => "inactive"}}}
        "/networks/homelab-iab-internal", _ -> {:error, {:not_found, ""}}
        "/volumes/" <> _, _ -> {:error, {:not_found, ""}}
        "/containers/" <> _, _ -> {:error, {:not_found, ""}}
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        send(test_pid, {:post, path, body})

        cond do
          String.contains?(path, "/containers/") and String.contains?(path, "/create") ->
            {:ok, %{"Id" => "new_container"}}

          true ->
            {:ok, %{}}
        end
      end)

      # Container GET keeps returning not_found, so wait_for_postgres times out;
      # we only care that the create requests were shaped correctly.
      assert {:error, :postgres_timeout} = Bootstrap.ensure_infrastructure()

      assert_received {:post, "/networks/create", %{"Name" => "homelab-iab-internal"}}
      assert_received {:post, "/volumes/create", %{"Name" => "homelab-iab-postgres-data"}}

      assert_received {:post, "/containers/create?name=homelab-iab-postgres", create_body}
      assert "POSTGRES_DB=homelab_prod" in create_body["Env"]
    end

    test "maps a network check failure to {:network_check_failed, _}" do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/networks/homelab-iab-internal", _ -> {:error, :econnrefused}
      end)

      assert {:error, {:network_check_failed, :econnrefused}} =
               Bootstrap.ensure_infrastructure()
    end

    test "times out when Postgres never reports healthy" do
      Application.put_env(:homelab, :bootstrap_wait, attempts: 1, interval_ms: 0)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/networks/homelab-iab-internal", _ -> {:ok, %{"Containers" => %{}}}
        "/volumes/" <> _, _ -> {:ok, %{}}
        # Running but never healthy.
        "/containers/" <> _, _ -> {:ok, %{"State" => %{"Running" => true}}}
      end)

      assert {:error, :postgres_timeout} = Bootstrap.ensure_infrastructure()
    end
  end

  describe "maybe_seed_from_env/0" do
    test "does nothing when HOMELAB_SEED_SETUP is not set" do
      System.delete_env("HOMELAB_SEED_SETUP")
      assert Bootstrap.maybe_seed_from_env() in [:ok, nil]
    end

    test "seeds settings and marks setup complete when OIDC is provided" do
      Homelab.Settings.init_cache()
      System.put_env("HOMELAB_SEED_SETUP", "true")
      System.put_env("HOMELAB_INSTANCE_NAME", "TestLab")
      System.put_env("HOMELAB_BASE_DOMAIN", "test.local")
      System.put_env("HOMELAB_OIDC_ISSUER", "https://id.test.local")
      System.put_env("HOMELAB_OIDC_CLIENT_ID", "test-client")

      on_exit(fn ->
        for k <- ~w(HOMELAB_SEED_SETUP HOMELAB_INSTANCE_NAME HOMELAB_BASE_DOMAIN
                    HOMELAB_OIDC_ISSUER HOMELAB_OIDC_CLIENT_ID),
            do: System.delete_env(k)
      end)

      Bootstrap.maybe_seed_from_env()

      assert Homelab.Settings.get("instance_name") == "TestLab"
      assert Homelab.Settings.get("base_domain") == "test.local"
      assert Homelab.Settings.setup_completed?()
    end

    test "seeds settings but leaves setup INCOMPLETE when OIDC is missing" do
      Homelab.Settings.init_cache()
      # The ETS cache leaks across tests (DB rolls back, cache doesn't), so a prior
      # test's seeded oidc_issuer/setup_completed would fool the guard. Clear them.
      Enum.each(~w(setup_completed oidc_issuer oidc_client_id), &Homelab.Settings.evict/1)
      System.put_env("HOMELAB_SEED_SETUP", "true")
      System.put_env("HOMELAB_INSTANCE_NAME", "TestLab")
      # No HOMELAB_OIDC_ISSUER / CLIENT_ID.

      on_exit(fn ->
        System.delete_env("HOMELAB_SEED_SETUP")
        System.delete_env("HOMELAB_INSTANCE_NAME")
      end)

      Bootstrap.maybe_seed_from_env()

      # Settings still seed, but marking complete without OIDC would trap the UI in
      # the / -> /auth/oidc -> /setup -> / redirect loop, so it must stay incomplete.
      assert Homelab.Settings.get("instance_name") == "TestLab"
      refute Homelab.Settings.setup_completed?()
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
