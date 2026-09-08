defmodule Homelab.Services.GatewayProvisionerTest do
  # async: false — toggles the global :gateway app-env that Config.gateway/0 reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Homelab.Services.GatewayProvisioner

  setup do
    prev_gateway = Application.get_env(:homelab, :gateway)
    prev_ensurer = Application.get_env(:homelab, :ingress_proxy_ensurer)

    on_exit(fn ->
      restore(:gateway, prev_gateway)
      restore(:ingress_proxy_ensurer, prev_ensurer)
    end)

    :ok
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, val), do: Application.put_env(:homelab, key, val)

  test "reports the missing DNS token (and does not crash) when the gateway is Traefik" do
    # No TRAEFIK_DNS_API_TOKEN in the test env, so ensure_traefik/0 short-circuits
    # with :dns_token_missing before ever touching the Docker daemon.
    Application.put_env(:homelab, :gateway, Homelab.Gateways.Traefik)
    start_supervised!(GatewayProvisioner)

    log =
      capture_log(fn ->
        assert GatewayProvisioner.ensure_now() == {:error, :dns_token_missing}
      end)

    assert log =~ "TRAEFIK_DNS_API_TOKEN is not set"
  end

  # `ensure_traefik/0` is a `with` with no `else`, so it returns whatever any clause
  # returned. A shape like this one matches no two-element `{:error, _}`, and a `cond`
  # that classified only the expected shapes would fall through to a silent `:ok` —
  # while still storing the value in `state.last`, so the `result == prev`
  # short-circuit would keep every later tick silent too. A service whose whole job is
  # announcing state transitions would go permanently mute on exactly the failure
  # class nothing else names.
  test "logs an unclassifiable failure rather than going permanently silent" do
    Application.put_env(:homelab, :gateway, Homelab.Gateways.Traefik)
    Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:error, :enoent, :extra} end)
    start_supervised!(GatewayProvisioner)

    log =
      capture_log(fn ->
        assert GatewayProvisioner.ensure_now() == {:error, :enoent, :extra}
      end)

    assert log =~ "Traefik provisioning failed: {:error, :enoent, :extra}"
  end

  test "says nothing when the first check simply finds Traefik already up" do
    Application.put_env(:homelab, :gateway, Homelab.Gateways.Traefik)
    Application.put_env(:homelab, :ingress_proxy_ensurer, fn -> {:ok, :already_running} end)
    start_supervised!(GatewayProvisioner)

    log =
      capture_log(fn ->
        assert GatewayProvisioner.ensure_now() == {:ok, :already_running}
      end)

    assert log == ""
  end

  test "no-ops when the active gateway is not Traefik" do
    Application.put_env(:homelab, :gateway, :some_other_gateway)
    start_supervised!(GatewayProvisioner)

    assert GatewayProvisioner.ensure_now() == nil
  end
end
