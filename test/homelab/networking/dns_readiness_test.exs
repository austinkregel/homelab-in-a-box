defmodule Homelab.Networking.DnsReadinessTest do
  # async: false — reads the global :dns_readiness_check override, which config/test.exs
  # pins to `true` for every other test in the suite.
  use ExUnit.Case, async: false

  alias Homelab.Networking.DnsReadiness

  setup do
    previous = Application.get_env(:homelab, :dns_readiness_check)
    on_exit(fn -> Application.put_env(:homelab, :dns_readiness_check, previous) end)
    :ok
  end

  describe "the override" do
    test "a boolean answers outright, without reaching for a resolver" do
      Application.put_env(:homelab, :dns_readiness_check, false)
      refute DnsReadiness.resolves?("example.com")

      Application.put_env(:homelab, :dns_readiness_check, true)
      assert DnsReadiness.resolves?("example.com")
    end

    test "a function is passed the domain" do
      Application.put_env(:homelab, :dns_readiness_check, fn domain ->
        domain == "expected.example.com"
      end)

      assert DnsReadiness.resolves?("expected.example.com")
      refute DnsReadiness.resolves?("other.example.com")
    end
  end

  describe "without an override" do
    setup do
      Application.delete_env(:homelab, :dns_readiness_check)
      :ok
    end

    # There is nothing to ask a resolver about, and a certificate request for an empty
    # identifier fails on malformed input rather than on propagation — which would read
    # as "still waiting for DNS" forever.
    test "a blank or missing domain is not ready" do
      refute DnsReadiness.resolves?("")
      refute DnsReadiness.resolves?("   ")
      refute DnsReadiness.resolves?(nil)
    end

    # The gate's whole risk is a false negative: it costs the operator TLS permanently,
    # to save a transient rate-limit. A name that cannot exist must therefore still be
    # the ONLY thing that holds it shut, and a resolver that will not answer must not.
    @tag :integration
    test "a name that cannot resolve is not ready" do
      refute DnsReadiness.resolves?(
               "definitely-not-a-real-domain-#{System.unique_integer([:positive])}.invalid"
             )
    end

    @tag :integration
    test "a name that does resolve is ready" do
      assert DnsReadiness.resolves?("example.com")
    end
  end
end
