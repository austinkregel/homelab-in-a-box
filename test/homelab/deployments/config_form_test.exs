defmodule Homelab.Deployments.ConfigFormTest do
  use ExUnit.Case, async: true

  alias Homelab.Deployments.ConfigForm

  describe "parse_ports/1 role handling" do
    test "infers a role only when the form carried none" do
      assert [%{"role" => "web"}] = ConfigForm.parse_ports(%{"0" => %{"internal" => "8080"}})
      assert [%{"role" => "database"}] = ConfigForm.parse_ports(%{"0" => %{"internal" => "5432"}})
    end

    # The bug behind the aut.hair 502: "other" was treated as "unset", so a port the
    # operator had deliberately demoted was re-promoted to "web" on the very next
    # save. With two conventional web ports (8000 AND 8080 are both on the list) the
    # proxy then silently re-pointed at whichever sorted first.
    test "an explicit role survives a save instead of being re-inferred" do
      ports =
        ConfigForm.parse_ports(%{
          "0" => %{"internal" => "8080", "role" => "other"},
          "1" => %{"internal" => "8000", "role" => "web"}
        })

      assert [%{"internal" => "8080", "role" => "other"}, %{"internal" => "8000", "role" => "web"}] =
               ports

      refute Enum.count(ports, &(&1["role"] == "web")) > 1,
             "a demoted port was silently promoted back to web"
    end
  end
end
