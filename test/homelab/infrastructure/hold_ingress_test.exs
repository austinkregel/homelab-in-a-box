defmodule Homelab.Infrastructure.HoldIngressTest do
  @moduledoc """
  The routing half of the hold pages (`HomelabWeb.HoldPage`): a catch-all router that
  answers for a host whose app has no router at all, and an `errors` middleware that
  answers for one whose app has a router but is not listening on it yet.

  Two of these tests are about the feature's blast radius rather than its behaviour. The
  entrypoint middleware in Traefik's STATIC config names a middleware from the file
  provider, and Traefik disables any router whose middleware does not resolve — so if
  the two halves ever stop agreeing on the name, or the file stops being written before
  the proxy is recreated, the failure is not "no hold pages", it is "no routing".
  """
  # async: false — reads global env (TRAEFIK_DNS_API_TOKEN, HOSTNAME) and touches
  # Settings (DB) through ensure_traefik/0.
  use Homelab.DataCase, async: false

  import Mox

  alias Homelab.Infrastructure

  setup :verify_on_exit!

  setup do
    Process.put(:docker_client, Homelab.Mocks.DockerClient)
    :ok
  end

  describe "hold_ingress_yaml/2" do
    setup do
      {:ok, parsed} =
        "communication.ventures"
        |> Infrastructure.hold_ingress_yaml("http://homelab-iab:4000")
        |> YamlElixir.read_from_string()

      {:ok, router: parsed["http"]["routers"]["hiab-hold"], config: parsed}
    end

    # Priority IS the mechanism. A deployment's own router comes from the Docker
    # provider at Traefik's default priority — the length of its rule — so the catch-all
    # has to sit below every rule that could exist, and a regexp rule is long. Lose this
    # line and the hold page outranks the apps it exists to cover for.
    test "the catch-all sits below every real route", %{router: router} do
      assert router["priority"] == 1
    end

    test "it matches any host under the base domain, and nothing that merely resembles it",
         %{router: router} do
      assert "HostRegexp(`" <> rest = router["rule"]
      pattern = String.trim_trailing(rest, "`)")

      assert Regex.match?(~r/#{pattern}/, "app.communication.ventures")
      assert Regex.match?(~r/#{pattern}/, "matrix.communication.ventures")

      # The dots are escaped, so this is a different domain rather than a match.
      refute Regex.match?(~r/#{pattern}/, "notcommunication.ventures")
      # The base domain itself belongs to the plane's own router, not to this one.
      refute Regex.match?(~r/#{pattern}/, "communication.ventures")
    end

    # `tls: {}` and no resolver: Traefik picks a stored certificate by SNI whichever
    # router asked for it, and the self ingress already provisions `*.<base>`. Naming a
    # resolver here would open an ACME order per held name — including for the ones that
    # exist only because somebody mistyped a subdomain.
    test "it reuses the wildcard rather than ordering a certificate per held name", %{
      router: router
    } do
      assert router["tls"] == %{}
      refute get_in(router, ["tls", "certResolver"])
    end

    test "the error middleware covers the dial failures, and not our own pages", %{config: config} do
      errors = config["http"]["middlewares"]["hiab-hold"]["errors"]

      assert errors["status"] == ["502", "504"]
      assert errors["query"] == "/_hiab/hold/{status}"
      assert errors["service"] == "hiab-hold"

      # 503 is what the catch-all's own pages answer with. Including it would send every
      # hold page back through the proxy to re-render itself.
      refute "503" in errors["status"]
    end

    test "the service points back at the plane, which renders the pages", %{config: config} do
      assert get_in(config, ["http", "services", "hiab-hold", "loadBalancer", "servers"]) ==
               [%{"url" => "http://homelab-iab:4000"}]
    end
  end

  describe "ensure_traefik/0" do
    setup do
      prev_token = System.get_env("TRAEFIK_DNS_API_TOKEN")
      prev_host = System.get_env("HOSTNAME")
      System.put_env("TRAEFIK_DNS_API_TOKEN", "cf-token-xyz")
      System.put_env("HOSTNAME", "abc123def456")

      on_exit(fn ->
        restore_env("TRAEFIK_DNS_API_TOKEN", prev_token)
        restore_env("HOSTNAME", prev_host)
      end)

      :ok
    end

    # Every call the run makes, in the order it made them.
    defp traefik_run(traefik_exists?) do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _opts ->
          {:ok, %{"Swarm" => %{"LocalNodeState" => "inactive", "ControlAvailable" => false}}}

        "/containers/abc123def456/json", _opts ->
          {:ok, %{"Name" => "/homelab-iab"}}

        "/containers/homelab-traefik/json", _opts ->
          if traefik_exists? do
            {:ok, %{"State" => %{"Running" => true}, "Config" => %{"Cmd" => [], "Env" => []}}}
          else
            {:error, {:not_found, %{}}}
          end

        _path, _opts ->
          {:error, {:not_found, %{}}}
      end)

      stub(Homelab.Mocks.DockerClient, :post_stream, fn _path, _opts -> :ok end)
      stub(Homelab.Mocks.DockerClient, :delete, fn _path, _opts -> {:ok, %{}} end)

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _opts ->
        if path == "/containers/create?name=homelab-traefik",
          do: send(test_pid, {:create, body})

        {:ok, %{"Id" => "traefik-id"}}
      end)

      stub(Homelab.Mocks.DockerClient, :upload_archive, fn container, path, tar ->
        send(test_pid, {:upload, container, path, tar})
        :ok
      end)

      Infrastructure.ensure_traefik()
    end

    # The invariant with the largest blast radius in this feature. The entrypoint
    # middleware below names `hiab-hold@file`; a Traefik that starts before that file
    # exists resolves nothing and disables EVERY router that inherits it. So on a box
    # where the proxy is already running — the one where there are app routers to lose —
    # the config has to be in the dynamic volume before anything can recreate it.
    test "writes the hold config before it can recreate a running proxy" do
      traefik_run(true)
      calls = drain()

      # The proxy in this run DOES get recreated (its Cmd has drifted), which is exactly
      # the moment the file has to already be there.
      assert :create in calls

      assert :hold_config in Enum.take_while(calls, &(&1 != :create)),
             "the hold config was written only after the proxy was recreated: #{inspect(calls)}"
    end

    test "writes it on the fresh-install path too, where there was no proxy to write into" do
      traefik_run(false)
      calls = drain()

      # The write before the create cannot land against a real daemon — there is no
      # container to write into, and only this mock accepts it — so what covers a first
      # boot is the write AFTER the proxy exists.
      assert :hold_config in Enum.drop_while(calls, &(&1 != :create)),
             "nothing wrote the hold config once the proxy existed: #{inspect(calls)}"
    end

    # The other half of the same invariant: the static config and the dynamic file have
    # to agree on the name, and nothing but a test can hold them together.
    test "the entrypoint attaches the middleware the hold config defines" do
      traefik_run(false)

      assert_received {:create, body}
      assert "--entryPoints.websecure.http.middlewares=hiab-hold@file" in body["Cmd"]

      {:ok, parsed} =
        Infrastructure.hold_ingress_yaml("example.com", "http://x:4000")
        |> YamlElixir.read_from_string()

      assert Map.has_key?(parsed["http"]["middlewares"], "hiab-hold")
    end
  end

  # Every recorded call in the order it was made, as a flat list of tags. The hold
  # config is identified by its filename, which the tar header carries.
  defp drain(acc \\ []) do
    receive do
      {:create, _body} -> drain([:create | acc])
      {:upload, _container, _path, tar} -> drain([upload_tag(tar) | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp upload_tag(tar) do
    if String.contains?(tar, "hold.yml"), do: :hold_config, else: :other_config
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
end
