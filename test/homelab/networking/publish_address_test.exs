defmodule Homelab.Networking.PublishAddressTest do
  @moduledoc """
  Choosing which of this host's addresses every A record points at.

  `async: false` for the reason `SpecBuilderWildcardTest` documents: the setting is read
  through `Settings.get_cached/2`, whose only seam is the global `:homelab_settings_cache`
  ETS table. Every async `DataCase` wipes that table in setup, so a value seeded from an
  async module can vanish mid-assertion.
  """
  use ExUnit.Case, async: false

  alias Homelab.Networking

  @setting Networking.publish_address_setting()

  defp choose(address) do
    Homelab.Settings.init_cache()
    :ets.insert(:homelab_settings_cache, {@setting, address})
    on_exit(fn -> :ets.delete(:homelab_settings_cache, @setting) end)
  end

  test "with no choice made, the detected address is used" do
    Homelab.Settings.init_cache()
    :ets.delete(:homelab_settings_cache, @setting)

    ip = Networking.host_ip()

    assert ip in Enum.map(Networking.host_addresses(), & &1.address)
  end

  test "a chosen address is what gets published" do
    # Deliberately NOT the one detection would pick where the host offers a second, so
    # the assertion cannot pass by coincidence.
    addresses = Enum.map(Networking.host_addresses(), & &1.address)
    chosen = Enum.find(addresses, &(&1 != Networking.host_ip())) || List.first(addresses)

    choose(chosen)

    assert Networking.host_ip() == chosen
  end

  # An interface can be renamed or a VPN can be down. A record pointing at an address the
  # host no longer holds resolves to nothing, which is worse than a detected one that at
  # least answers -- so the stored value is checked against the interfaces, not trusted.
  test "an address the host no longer holds falls back to detection" do
    choose("203.0.113.9")

    ip = Networking.host_ip()

    refute ip == "203.0.113.9"
    assert ip in Enum.map(Networking.host_addresses(), & &1.address)
  end

  test "a blank choice is not a choice" do
    choose("")

    assert Networking.host_ip() in Enum.map(Networking.host_addresses(), & &1.address)
  end

  test "the published address is what deployment DNS records use" do
    chosen = Networking.host_addresses() |> List.first() |> Map.fetch!(:address)
    choose(chosen)

    assert %{internal_ip: ^chosen, public_ip: ^chosen} = Homelab.Deployments.detect_ip_config()
  end
end
