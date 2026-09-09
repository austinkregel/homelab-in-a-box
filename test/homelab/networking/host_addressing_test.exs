defmodule Homelab.Networking.HostAddressingTest do
  @moduledoc """
  Which networks this host is on, and which address other machines reach it at.

  One answers a TCP route's allowlist, the other is what every deployment's A record
  points at, and both used to be able to name a Docker bridge — an address reachable
  from nowhere.

  These run against the real interfaces of whatever machine the suite is on, so they
  assert the SHAPE and the exclusions rather than specific addresses: a CI runner and a
  developer's laptop are on different networks, but on neither is a container bridge the
  right answer.
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

  describe "host_ip/0" do
    test "is an address on one of this host's own networks" do
      ip = Networking.host_ip()

      assert is_binary(ip)
      assert {:ok, _address} = :inet.parse_address(String.to_charlist(ip))

      # Whatever the routing table picked has to belong to a network this host is on --
      # otherwise it is not an address anything reaches this host at.
      assert Enum.any?(Networking.host_networks(), &contains?(&1, ip)),
             "#{ip} is not within any of #{inspect(Networking.host_networks())}"
    end

    # The bug this replaced: `:inet.getifaddrs/0` lists the daemon's bridges too, so the
    # first non-loopback address could be `172.17.0.1` -- reachable from nowhere, and
    # published as the A record for every app on the box.
    test "is never a Docker bridge address" do
      bridge_addresses =
        case :inet.getifaddrs() do
          {:ok, interfaces} ->
            for {name, opts} <- interfaces,
                docker_interface?(to_string(name)),
                addr <- Keyword.get_values(opts, :addr),
                tuple_size(addr) == 4,
                do: addr |> :inet.ntoa() |> to_string()

          _ ->
            []
        end

      refute Networking.host_ip() in bridge_addresses
    end

    test "is never loopback" do
      refute String.starts_with?(Networking.host_ip(), "127.")
    end

    test "agrees with what detect_ip_config publishes" do
      assert %{internal_ip: ip, public_ip: ip} = Homelab.Deployments.detect_ip_config()
      assert ip == Networking.host_ip()
    end
  end

  defp docker_interface?(name) do
    name in ["docker0", "docker_gwbridge"] or String.starts_with?(name, ["br-", "veth"])
  end

  defp contains?(cidr, ip) do
    [network, bits] = String.split(cidr, "/")
    prefix = String.to_integer(bits)

    {:ok, {na, nb, nc, nd}} = :inet.parse_address(String.to_charlist(network))
    {:ok, {ia, ib, ic, id}} = :inet.parse_address(String.to_charlist(ip))

    <<net::size(prefix), _::bitstring>> = <<na, nb, nc, nd>>
    <<candidate::size(prefix), _::bitstring>> = <<ia, ib, ic, id>>

    net == candidate
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
