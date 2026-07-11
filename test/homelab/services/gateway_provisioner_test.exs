defmodule Homelab.Services.GatewayProvisionerTest do
  # async: false — toggles the global :gateway app-env that Config.gateway/0 reads.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Homelab.Services.GatewayProvisioner

  setup do
    prev = Application.get_env(:homelab, :gateway)
    on_exit(fn -> restore(:gateway, prev) end)
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

  test "no-ops when the active gateway is not Traefik" do
    Application.put_env(:homelab, :gateway, :some_other_gateway)
    start_supervised!(GatewayProvisioner)

    assert GatewayProvisioner.ensure_now() == nil
  end
end
