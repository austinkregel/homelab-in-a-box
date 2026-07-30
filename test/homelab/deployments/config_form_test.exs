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

      assert [
               %{"internal" => "8080", "role" => "other"},
               %{"internal" => "8000", "role" => "web"}
             ] =
               ports

      refute Enum.count(ports, &(&1["role"] == "web")) > 1,
             "a demoted port was silently promoted back to web"
    end
  end

  describe "parse_ports/1 protocol handling" do
    test "keeps udp and normalizes casing" do
      assert [%{"protocol" => "udp"}] =
               ConfigForm.parse_ports(%{"0" => %{"internal" => "27900", "protocol" => "udp"}})

      assert [%{"protocol" => "udp"}] =
               ConfigForm.parse_ports(%{"0" => %{"internal" => "27900", "protocol" => "UDP"}})
    end

    test "a form that posts no protocol field yields tcp, never nil" do
      # A cached page or a submit path that has not grown the input must still produce a
      # port map that answers the protocol question, since the orchestrators key on it.
      assert [%{"protocol" => "tcp"}] =
               ConfigForm.parse_ports(%{"0" => %{"internal" => "8080"}})
    end

    test "an unrecognized protocol falls back to tcp rather than failing the deploy" do
      assert [%{"protocol" => "tcp"}] =
               ConfigForm.parse_ports(%{"0" => %{"internal" => "8080", "protocol" => "sctp"}})
    end
  end
end
