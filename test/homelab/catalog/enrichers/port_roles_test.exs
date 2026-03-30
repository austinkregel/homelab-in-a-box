defmodule Homelab.Catalog.Enrichers.PortRolesTest do
  use ExUnit.Case, async: true

  alias Homelab.Catalog.Enrichers.PortRoles

  describe "infer/1" do
    test "identifies web ports" do
      for port <- ~w(80 443 3000 8080 8443 9000) do
        assert PortRoles.infer(port) == "web", "Expected port #{port} to be web"
      end
    end

    test "identifies SSH ports" do
      assert PortRoles.infer("22") == "ssh"
      assert PortRoles.infer("2222") == "ssh"
    end

    test "identifies database ports" do
      assert PortRoles.infer("3306") == "database"
      assert PortRoles.infer("5432") == "database"
      assert PortRoles.infer("27017") == "database"
      assert PortRoles.infer("6379") == "database"
    end

    test "identifies mail ports" do
      for port <- ~w(25 465 587 993 143) do
        assert PortRoles.infer(port) == "mail", "Expected port #{port} to be mail"
      end
    end

    test "identifies DNS ports" do
      assert PortRoles.infer("53") == "dns"
    end

    test "returns other for unknown ports" do
      assert PortRoles.infer("12345") == "other"
    end

    test "accepts integers as strings" do
      assert PortRoles.infer(80) == "web"
    end
  end

  describe "available_roles/0" do
    test "returns list of role tuples" do
      roles = PortRoles.available_roles()
      assert is_list(roles)
      assert {"Web", "web"} in roles
      assert {"Database", "database"} in roles
    end
  end
end
