defmodule Homelab.Infrastructure.RegistryInfraTest do
  @moduledoc """
  Covers the self-hosted registry infrastructure: the Traefik wildcard DNS-01
  reconfiguration, the htpasswd generator, and the registry credential guard.
  """
  # async: false — reads/writes global env (TRAEFIK_DNS_API_TOKEN, :homelab creds)
  # and touches Settings (DB) via ensure_traefik/ensure_registry.
  use Homelab.DataCase, async: false

  import ExUnit.CaptureLog
  import Mox

  alias Homelab.Infrastructure
  alias Homelab.Infrastructure.Htpasswd
  alias Homelab.Infrastructure.Registry

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  # `ensure_traefik/0` attaches the plane's own route on both sides of the recreate, and
  # both attaches need a URL back to this container. State it rather than let it probe
  # $HOSTNAME and inspect a container these tests never mock — the subject here is the
  # Traefik `Cmd`, and the attach is collateral.
  defp stub_self_service_url do
    prev = Application.get_env(:homelab, :self_service_url)
    Application.put_env(:homelab, :self_service_url, "http://homelab-iab:4000")
    on_exit(fn -> restore_app_env(:self_service_url, prev) end)
  end

  describe "ensure_traefik/0 routing providers" do
    setup do
      prev = System.get_env("TRAEFIK_DNS_API_TOKEN")
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")
      on_exit(fn -> restore_env("TRAEFIK_DNS_API_TOKEN", prev) end)
      stub_self_service_url()
      :ok
    end

    # The Cmd Traefik would be created with, on a daemon in the given swarm state.
    defp traefik_cmd(swarm_state) do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _opts ->
          {:ok,
           %{
             "Swarm" => %{
               "LocalNodeState" => swarm_state,
               "ControlAvailable" => swarm_state == "active"
             }
           }}

        _path, _opts ->
          {:error, {:not_found, %{}}}
      end)

      # `ensure_traefik/0` drops the internal-TLS serversTransport into the proxy's
      # dynamic dir on both sides of the recreate. Incidental to what this test reads
      # (the Cmd), but it is a real Docker call and Mox has to know about it.
      stub(Homelab.Mocks.DockerClient, :upload_archive, fn _name, _path, _tar -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        if path == "/containers/create?name=homelab-traefik",
          do: send(test_pid, {:create, body})

        {:ok, %{"Id" => "traefik-id"}}
      end)

      Infrastructure.ensure_traefik()

      assert_received {:create, body}
      body["Cmd"]
    end

    test "enables the Swarm provider when the daemon is in swarm mode" do
      cmd = traefik_cmd("active")

      # Without this Traefik never sees a Swarm deployment's routers at all: Swarm
      # keeps the traefik.* labels on the SERVICE, and the docker provider only ever
      # watches containers.
      assert "--providers.swarm=true" in cmd
      assert "--providers.swarm.exposedbydefault=false" in cmd
      # Kept alongside it — an adopted stack's containers still route by container label.
      assert "--providers.docker=true" in cmd
    end

    test "omits the Swarm provider on a non-swarm daemon (there is no swarm API to talk to)" do
      cmd = traefik_cmd("inactive")

      refute Enum.any?(cmd, &String.starts_with?(&1, "--providers.swarm"))
      assert "--providers.docker=true" in cmd
    end
  end

  describe "ensure_traefik/0 wildcard DNS-01" do
    setup do
      prev = System.get_env("TRAEFIK_DNS_API_TOKEN")
      on_exit(fn -> restore_env("TRAEFIK_DNS_API_TOKEN", prev) end)
      stub_self_service_url()
      :ok
    end

    test "fails closed with no Docker calls when the token env var is missing" do
      System.delete_env("TRAEFIK_DNS_API_TOKEN")

      # The missing token is what this test stages, and `ensure_traefik/0` reports it at
      # error severity — captured so the expected complaint does not read as a real one
      # in the suite's output.
      log =
        capture_log(fn ->
          # No mock expectations set → any Docker call would fail verify_on_exit!.
          assert {:error, :dns_token_missing} = Infrastructure.ensure_traefik()
        end)

      assert log =~ "TRAEFIK_DNS_API_TOKEN is not set"
    end

    test "injects DNS-01 provider flags and the CF token env when creating Traefik" do
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")
      test_pid = self()

      # No existing Traefik container and no existing network (both 404).
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      # `ensure_traefik/0` drops the internal-TLS serversTransport into the proxy's
      # dynamic dir on both sides of the recreate. Incidental to what this test reads
      # (the Cmd), but it is a real Docker call and Mox has to know about it.
      stub(Homelab.Mocks.DockerClient, :upload_archive, fn _name, _path, _tar -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        cond do
          path == "/containers/create?name=homelab-traefik" ->
            send(test_pid, {:create, body})
            {:ok, %{"Id" => "traefik-id"}}

          String.ends_with?(path, "/start") ->
            {:ok, %{}}

          true ->
            {:ok, %{}}
        end
      end)

      Infrastructure.ensure_traefik()

      assert_received {:create, body}
      cmd = body["Cmd"]
      assert "--certificatesresolvers.letsencrypt.acme.dnschallenge=true" in cmd
      assert "--certificatesresolvers.letsencrypt.acme.dnschallenge.provider=cloudflare" in cmd
      refute Enum.any?(cmd, &String.contains?(&1, "httpchallenge"))
      assert "CF_DNS_API_TOKEN=cf-token-xyz" in body["Env"]
    end

    # `create_system_container/2` gates its success clause on an `Id` in the create
    # response, so a 2xx reply without one lands in an `else` that matched only
    # `{:error, reason}`. The `WithClauseError` that raised passes through
    # `ensure_traefik/0` unchanged and reaches `do_deploy/1`, which has no rescue.
    test "a create response carrying no Id fails the ensure instead of raising" do
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")

      # Nothing exists yet, so the ensure takes the create path.
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
      stub(Homelab.Mocks.DockerClient, :upload_archive, fn _name, _path, _tar -> :ok end)

      # A 2xx with an empty body: accepted by the network create above, and the shape
      # the container create must not choke on.
      stub(Homelab.Mocks.DockerClient, :post, fn _path, _body, _opts -> {:ok, %{}} end)

      assert {:error, {:create_failed, {:ok, %{}}}} = Infrastructure.ensure_traefik()
    end

    test "force-recreates a running Traefik whose command lacks the DNS-01 flags" do
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/homelab-traefik/json", _opts ->
          # Running, but with the OLD HTTP-01 command (drift).
          {:ok,
           %{
             "State" => %{"Running" => true},
             "Config" => %{
               "Cmd" => ["--certificatesresolvers.letsencrypt.acme.httpchallenge=true"],
               "Env" => []
             }
           }}

        _path, _opts ->
          {:error, {:not_found, %{}}}
      end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      # `ensure_traefik/0` drops the internal-TLS serversTransport into the proxy's
      # dynamic dir on both sides of the recreate. Incidental to what this test reads
      # (the Cmd), but it is a real Docker call and Mox has to know about it.
      stub(Homelab.Mocks.DockerClient, :upload_archive, fn _name, _path, _tar -> :ok end)

      stub(Homelab.Mocks.DockerClient, :delete, fn path, _opts ->
        send(test_pid, {:deleted, path})
        {:ok, %{}}
      end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          path == "/containers/create?name=homelab-traefik" ->
            send(test_pid, :recreated)
            {:ok, %{"Id" => "traefik-id"}}

          true ->
            {:ok, %{}}
        end
      end)

      Infrastructure.ensure_traefik()

      assert_received {:deleted, "/containers/homelab-traefik?force=true"}
      assert_received :recreated
    end
  end

  describe "Htpasswd.generate/2" do
    test "runs htpasswd in a throwaway container and returns the bcrypt line" do
      line = "bob:$2y$05$abcdefghijklmnopqrstuv"
      # Frame the stdout like Docker's multiplexed log stream (8-byte header).
      framed = <<1, 0, 0, 0, byte_size(line)::32>> <> line

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, _body, _opts ->
        cond do
          path == "/containers/create" -> {:ok, %{"Id" => "htp"}}
          String.ends_with?(path, "/start") -> {:ok, %{}}
          String.ends_with?(path, "/wait") -> {:ok, %{"StatusCode" => 0}}
          true -> {:ok, %{}}
        end
      end)

      stub(Homelab.Mocks.DockerClient, :get, fn path, _opts ->
        assert path =~ "/logs?stdout=true"
        {:ok, framed}
      end)

      stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

      assert {:ok, ^line} = Htpasswd.generate("bob", "s3cret")
    end
  end

  describe "Registry.ensure_registry/0" do
    test "returns :missing_credentials with no Docker calls when creds are unset" do
      prev = Application.get_env(:homelab, :registry_credentials)
      Application.delete_env(:homelab, :registry_credentials)
      on_exit(fn -> restore_app_env(:registry_credentials, prev) end)

      assert {:error, :missing_credentials} = Registry.ensure_registry()
    end

    test "creates the RW registry with auth env, wildcard Traefik labels, and htpasswd upload" do
      with_registry_config(fn ->
        test_pid = self()
        line = "bob:$2y$05$abcdefghijklmnopqrstuv"
        framed = <<1, 0, 0, 0, byte_size(line)::32>> <> line

        # Network exists; traefik already on the network; htpasswd logs framed.
        stub(Homelab.Mocks.DockerClient, :get, fn
          "/networks/" <> _, _opts ->
            {:ok, %{}}

          "/containers/homelab-traefik/json", _opts ->
            {:ok,
             %{
               "Id" => "tid",
               "NetworkSettings" => %{"Networks" => %{"homelab-iab-internal" => %{}}}
             }}

          path, _opts ->
            if path =~ "/logs?stdout=true", do: {:ok, framed}, else: {:ok, %{}}
        end)

        stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
        stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

        stub(Homelab.Mocks.DockerClient, :upload_archive, fn _c, path, _tar ->
          send(test_pid, {:archive, path})
          :ok
        end)

        stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
          cond do
            path == "/containers/create?name=homelab-registry" ->
              send(test_pid, {:registry_body, body})
              {:ok, %{"Id" => "reg"}}

            path == "/containers/create" ->
              {:ok, %{"Id" => "htp"}}

            String.ends_with?(path, "/wait") ->
              {:ok, %{"StatusCode" => 0}}

            true ->
              {:ok, %{}}
          end
        end)

        assert {:ok, :started} = Registry.ensure_registry()

        assert_received {:registry_body, body}
        assert body["Image"] == "registry:2"
        assert "REGISTRY_AUTH=htpasswd" in body["Env"]
        labels = body["Labels"]
        assert labels["homelab.system.role"] == "registry"
        assert labels["traefik.http.routers.registry.rule"] == "Host(`registry.example.com`)"
        assert labels["traefik.http.routers.registry.tls.domains[0].sans"] == "*.example.com"
        sources = Enum.map(body["HostConfig"]["Mounts"], & &1["Source"])
        assert "homelab-registry-data" in sources
        assert "homelab-registry-auth" in sources

        assert_received {:archive, "/auth"}
      end)
    end

    test "creates the pull-through mirror as a proxy to docker.io" do
      with_registry_config(fn ->
        test_pid = self()

        stub(Homelab.Mocks.DockerClient, :get, fn
          "/containers/homelab-traefik/json", _opts ->
            {:ok,
             %{
               "Id" => "tid",
               "NetworkSettings" => %{"Networks" => %{"homelab-iab-internal" => %{}}}
             }}

          _path, _opts ->
            {:ok, %{}}
        end)

        stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
        stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

        stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
          cond do
            path == "/containers/create?name=homelab-registry-proxy" ->
              send(test_pid, {:proxy_body, body})
              {:ok, %{"Id" => "proxy"}}

            true ->
              {:ok, %{}}
          end
        end)

        assert {:ok, :started} = Registry.ensure_registry_proxy()

        assert_received {:proxy_body, body}
        assert "REGISTRY_PROXY_REMOTEURL=https://registry-1.docker.io" in body["Env"]
        labels = body["Labels"]
        assert labels["homelab.system.role"] == "registry-mirror"

        assert labels["traefik.http.routers.registryproxy.rule"] ==
                 "Host(`proxy-registry.example.com`)"
      end)
    end
  end

  # Runs `fun` with base_domain=example.com and registry credentials set, restoring after.
  defp with_registry_config(fun) do
    prev_domain = Application.get_env(:homelab, :base_domain)
    prev_creds = Application.get_env(:homelab, :registry_credentials)
    Application.put_env(:homelab, :base_domain, "example.com")
    Application.put_env(:homelab, :registry_credentials, {"bob", "s3cret"})

    try do
      fun.()
    after
      restore_app_env(:base_domain, prev_domain)
      restore_app_env(:registry_credentials, prev_creds)
    end
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, val), do: System.put_env(key, val)

  defp restore_app_env(key, nil), do: Application.delete_env(:homelab, key)
  defp restore_app_env(key, val), do: Application.put_env(:homelab, key, val)
end
