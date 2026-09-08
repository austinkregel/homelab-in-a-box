defmodule Homelab.Networking.TlsProbeCoverageTest do
  @moduledoc """
  Does the probe read the names a certificate actually authenticates?

  Separate from `TlsProbeTest` because that one is tagged `:integration` and excluded
  from a default run — which is exactly how a probe that never read a single SAN shipped
  under an assertion that a SAN was present. These serve their own certificate to
  themselves over loopback, so they run everywhere and need no internet.

  The shape under test is the one every homelab host lands on: a Let's Encrypt leaf names
  its FIRST domain in the common name and every name it covers in `subjectAltName`, so a
  deployment reached off a wildcard (`lidarr.homelab.example.com`, on the cert whose common
  name is `homelab.example.com`) is authenticated by a SAN and by nothing else. A probe
  reading only the common name calls that a name mismatch, and `VerifyPublicUrl` reports
  every such release as unreachable while a browser loads the page happily.
  """
  use ExUnit.Case, async: true

  alias Homelab.Networking.TlsProbe

  describe "a certificate whose common name is NOT the host" do
    test "is covered when a SAN names the host" do
      port = serve(cn: "homelab.example.com", sans: ["homelab.example.com", "localhost"])

      assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

      assert cert.subject == "homelab.example.com"
      assert "localhost" in cert.sans
      assert cert.covers_domain?
      refute cert.self_signed?
      refute cert.status == :name_mismatch
    end

    test "is a name mismatch when no SAN names the host" do
      port = serve(cn: "homelab.example.com", sans: ["homelab.example.com", "lidarr.example.com"])

      assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

      refute cert.covers_domain?
      assert cert.status == :name_mismatch
    end
  end

  describe "wildcard SANs" do
    # The name every routed deployment is actually covered by. Only the loopback host
    # resolves here, so this proves the wildcard reaches the matcher as written; the
    # matcher's one-label rule is what the negative below pins down.
    test "survive parsing with the star intact" do
      port =
        serve(cn: "homelab.example.com", sans: ["homelab.example.com", "*.homelab.example.com"])

      assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

      assert "*.homelab.example.com" in cert.sans
    end

    # A wildcard covers one label UNDER the parent, never the parent itself -- and
    # `localhost` is a single label with no parent to be under.
    test "do not cover a name that is not one label under the parent" do
      port = serve(cn: "unrelated.test", sans: ["*.localhost"])

      assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

      refute cert.covers_domain?
      assert cert.status == :name_mismatch
    end
  end

  test "a SAN matches the host case-insensitively" do
    port = serve(cn: "unrelated.test", sans: ["LOCALHOST"])

    assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

    assert cert.covers_domain?
  end

  test "a certificate carrying no extensions at all reports no SANs" do
    port = serve(cn: "localhost", sans: nil)

    assert {:ok, cert} = TlsProbe.inspect_domain("localhost", port: port)

    assert cert.sans == []
    # Still covered: the common name names the host.
    assert cert.covers_domain?
  end

  # -- A TLS server presenting a certificate we describe by hand --

  # Accepts exactly one connection, which is all the probe opens. Linked to the test so
  # it dies with it, and `handshake/2` is allowed to fail: the probe reads the peer
  # certificate and closes, which the server may see as an aborted handshake.
  defp serve(opts) do
    {der, key} = certificate(opts)

    {:ok, listener} =
      :ssl.listen(0,
        ip: {127, 0, 0, 1},
        cert: der,
        key: {:RSAPrivateKey, :public_key.der_encode(:RSAPrivateKey, key)},
        reuseaddr: true,
        active: false,
        versions: [:"tlsv1.2", :"tlsv1.3"]
      )

    {:ok, {_ip, port}} = :ssl.sockname(listener)

    spawn_link(fn ->
      with {:ok, socket} <- :ssl.transport_accept(listener, 5_000) do
        :ssl.handshake(socket, 5_000)
      end
    end)

    on_exit(fn -> :ssl.close(listener) end)

    port
  end

  @rsa_encryption {1, 2, 840, 113_549, 1, 1, 1}
  @sha256_with_rsa {1, 2, 840, 113_549, 1, 1, 11}
  @common_name {2, 5, 4, 3}
  @subject_alt_name {2, 5, 29, 17}

  # Issued by a name that is NOT the subject, even though the same key signs it: the
  # probe calls a certificate self-signed when issuer and subject match, and that verdict
  # outranks every other one. A test certificate that looked self-signed could never
  # report the name mismatch these tests are about.
  defp certificate(opts) do
    key = :public_key.generate_key({:rsa, 2048, 65_537})
    public_key = {:RSAPublicKey, elem(key, 2), elem(key, 3)}
    subject = rdn(Keyword.fetch!(opts, :cn))

    tbs =
      {:OTPTBSCertificate, :v3, 1, {:SignatureAlgorithm, @sha256_with_rsa, :asn1_NOVALUE},
       rdn("Homelab Test Issuer"),
       {:Validity, {:utcTime, ~c"250101000000Z"}, {:utcTime, ~c"350101000000Z"}}, subject,
       {:OTPSubjectPublicKeyInfo, {:PublicKeyAlgorithm, @rsa_encryption, :asn1_NOVALUE},
        public_key}, :asn1_NOVALUE, :asn1_NOVALUE, extensions(Keyword.fetch!(opts, :sans))}

    {:public_key.pkix_sign(tbs, key), key}
  end

  # `:asn1_NOVALUE`, not `[]`: that is what OTP hands back for a certificate with no
  # extensions, and telling it apart from an empty extension list is the distinction the
  # SAN reader has to get right.
  defp extensions(nil), do: :asn1_NOVALUE

  defp extensions(sans) do
    [{:Extension, @subject_alt_name, false, Enum.map(sans, &{:dNSName, String.to_charlist(&1)})}]
  end

  defp rdn(common_name) do
    {:rdnSequence, [[{:AttributeTypeAndValue, @common_name, {:utf8String, common_name}}]]}
  end
end
