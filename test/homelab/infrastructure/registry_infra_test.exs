defmodule Homelab.Infrastructure.RegistryInfraTest do
  @moduledoc """
  Covers the self-hosted registry infrastructure: the Traefik wildcard DNS-01
  reconfiguration, the htpasswd generator, and the registry credential guard.
  """
  # async: false — reads/writes global env (TRAEFIK_DNS_API_TOKEN, :homelab creds)
  # and touches Settings (DB) via ensure_traefik/ensure_registry.
  use Homelab.DataCase, async: false

  import Mox

  alias Homelab.Infrastructure
  alias Homelab.Infrastructure.Htpasswd
  alias Homelab.Infrastructure.Registry

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "ensure_traefik/0 wildcard DNS-01" do
    setup do
      prev = System.get_env("TRAEFIK_DNS_API_TOKEN")
      on_exit(fn -> restore_env("TRAEFIK_DNS_API_TOKEN", prev) end)
      :ok
    end

    test "fails closed with no Docker calls when the token env var is missing" do
      System.delete_env("TRAEFIK_DNS_API_TOKEN")
      # No mock expectations set → any Docker call would fail verify_on_exit!.
      assert {:error, :dns_token_missing} = Infrastructure.ensure_traefik()
    end

    test "injects DNS-01 provider flags and the CF token env when creating Traefik" do
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")
      test_pid = self()

      # No existing Traefik container and no existing network (both 404).
      stub(Homelab.Mocks.DockerClient, :get, fn _path, _opts -> {:error, {:not_found, %{}}} end)
      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)

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
             %{"Id" => "tid", "NetworkSettings" => %{"Networks" => %{"homelab-internal" => %{}}}}}

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
             %{"Id" => "tid", "NetworkSettings" => %{"Networks" => %{"homelab-internal" => %{}}}}}

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
