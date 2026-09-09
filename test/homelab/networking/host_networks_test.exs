defmodule Homelab.Networking.HostNetworksTest do
  @moduledoc """
  The CIDRs offered as values for a TCP route's allowlist.

  These run against the real interfaces of whatever machine the suite is on, so they
  assert the SHAPE and the exclusions rather than specific addresses — a CI runner and a
  developer's laptop are on different networks, but neither should ever be told to allow
  a Docker bridge.
  """
  use ExUnit.Case, async: true

  alias Homelab.Networking

  test "every entry is a well-formed CIDR" do
    for cidr <- Networking.host_networks() do
      assert [network, bits] = String.split(cidr, "/")
      assert {:ok, _address} = :inet.parse_address(String.to_charlist(network))
      assert String.to_integer(bits) in 0..32
    end
  end

  # The whole point of the list: a range covering this host's own bridges would admit
  # every container on the box, which is the opposite of what an allowlist is for.
  test "no Docker bridge address is offered" do
    docker_networks =
      case :inet.getifaddrs() do
        {:ok, interfaces} ->
          for {name, opts} <- interfaces,
              to_string(name) == "docker0" or String.starts_with?(to_string(name), "br-"),
              addr = Keyword.get(opts, :addr),
              tuple_size(addr) == 4,
              do: addr |> :inet.ntoa() |> to_string()

        _ ->
          []
      end

    offered = Networking.host_networks()

    for docker_ip <- docker_networks do
      [a, b | _] = String.split(docker_ip, ".")
      refute Enum.any?(offered, &String.starts_with?(&1, "#{a}.#{b}."))
    end
  end

  test "loopback is never offered" do
    refute Enum.any?(Networking.host_networks(), &String.starts_with?(&1, "127."))
  end

  # The address is masked down to the network, so the value can be pasted into an
  # allowlist as-is rather than naming one host.
  test "entries are network addresses, not interface addresses" do
    for cidr <- Networking.host_networks() do
      [network, bits] = String.split(cidr, "/")
      {:ok, {a, b, c, d}} = :inet.parse_address(String.to_charlist(network))
      prefix = String.to_integer(bits)
      host_bits = 32 - prefix

      # Every bit below the prefix is zero exactly when this is a network address and
      # not the interface's own address.
      <<_network::size(prefix), remainder::size(host_bits)>> = <<a, b, c, d>>

      assert remainder == 0, "#{cidr} names a host, not a network"
    end
  end
end
