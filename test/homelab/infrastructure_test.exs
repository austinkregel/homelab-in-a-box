defmodule Homelab.InfrastructureTest do
  use ExUnit.Case, async: true

  alias Homelab.Infrastructure

  describe "available_services/0" do
    test "returns a list of system service templates" do
      services = Infrastructure.available_services()
      assert is_list(services)
      assert length(services) > 0

      keys = Enum.map(services, & &1.key)
      assert "traefik" in keys
      assert "pihole" in keys
    end

    test "each service has key, name, and image" do
      for service <- Infrastructure.available_services() do
        assert Map.has_key?(service, :key)
        assert Map.has_key?(service, :name)
        assert Map.has_key?(service, :image)
        assert is_binary(service.name)
        assert is_binary(service.image)
      end
    end
  end

  describe "provision_service/1" do
    test "returns error for unknown service key" do
      assert {:error, :unknown_service} = Infrastructure.provision_service("nonexistent")
    end
  end
end
