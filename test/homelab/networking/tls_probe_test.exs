defmodule Homelab.Networking.TlsProbeTest do
  @moduledoc """
  The probe exists because the gateway's cert "status" is fiction:
  `Traefik.check_tls_expiry/1` has no notAfter to read and falls back to "90 days from
  now", and `provision_tls/1` calls a domain :active whenever a ROUTER exists — which
  it does even while Traefik serves its self-signed default because ACME failed.

  These tests hit the real internet, so they are tagged :integration and excluded by
  default. They are the only thing that proves the parser against certificates we did
  not construct ourselves.
  """
  use ExUnit.Case, async: true

  alias Homelab.Networking.TlsProbe

  @moduletag :integration

  test "reads a real certificate's issuer, expiry and names" do
    assert {:ok, cert} = TlsProbe.inspect_domain("github.com")

    assert cert.status == :valid
    refute cert.self_signed?
    assert cert.covers_domain?
    assert cert.issuer != ""
    assert cert.days_remaining > 0
    assert "github.com" in cert.sans
  end

  # The headline case: Traefik serves this shape when ACME never issued for a custom
  # domain, and today's code would still call it "active".
  test "flags a self-signed certificate" do
    assert {:ok, cert} = TlsProbe.inspect_domain("self-signed.badssl.com")
    assert cert.status == :self_signed
    assert cert.self_signed?
  end

  test "flags an expired certificate with a negative day count" do
    assert {:ok, cert} = TlsProbe.inspect_domain("expired.badssl.com")
    assert cert.status == :expired
    assert cert.days_remaining < 0
  end

  test "flags a certificate served for a different name" do
    assert {:ok, cert} = TlsProbe.inspect_domain("wrong.host.badssl.com")
    assert cert.status == :name_mismatch
    refute cert.covers_domain?
  end

  test "reports a handshake failure rather than raising" do
    assert {:error, {:handshake_failed, _}} =
             TlsProbe.inspect_domain("no-such-host.invalid", timeout: 2_000)
  end
end
