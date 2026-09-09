defmodule Homelab.Networking.TlsProbe do
  @moduledoc """
  Reads the certificate a domain is ACTUALLY serving, by completing a TLS handshake
  against it and inspecting the leaf the server presents.

  This is deliberately not the gateway's opinion. Traefik's router API reports no
  `notAfter`, so `Traefik.check_tls_expiry/1` falls back to "90 days from now" — an
  invented date — and `provision_tls/1` reports `:active` merely because a router
  exists, which is true even while Traefik is serving its built-in self-signed
  `TRAEFIK DEFAULT CERT` because ACME failed. A wildcard covers `*.<base_domain>`,
  but an app on its own apex domain (example.org) needs its own certificate, and that
  is exactly the case where a silent fallback to the default cert looks fine and
  serves browser warnings.

  The handshake is the ground truth: it answers "is this a real, trusted cert for
  this name, and when does it expire" the same way a browser would.

  Certificate verification is deliberately `:verify_none` — an untrusted or expired
  cert is a RESULT to report, not an error to fail on. We inspect what is served
  rather than refusing to look at it.
  """

  require Logger

  @type result :: %{
          status: :valid | :expiring | :expired | :self_signed | :name_mismatch,
          issuer: String.t(),
          subject: String.t(),
          sans: [String.t()],
          not_after: DateTime.t(),
          days_remaining: integer(),
          self_signed?: boolean(),
          covers_domain?: boolean()
        }

  # Traefik's built-in placeholder, served when no real cert matches the SNI name.
  @traefik_default "TRAEFIK DEFAULT CERT"
  @expiring_within_days 21

  @doc """
  Inspects the certificate served for `domain` on `port` (443 by default).

  Returns `{:error, reason}` when the handshake cannot be completed at all — the
  name does not resolve, nothing is listening, the port is closed. That is itself
  worth surfacing: it means the app is not reachable over TLS.

  ## Options

    * `:port` — defaults to 443.
    * `:timeout` — defaults to 5s.
    * `:starttls` — `:postgres` to negotiate the upgrade the way `libpq` does before
      handshaking. Required to probe a TCP route to a database; see `tls_connect/5`.
  """
  @spec inspect_domain(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def inspect_domain(domain, opts \\ []) when is_binary(domain) do
    port = Keyword.get(opts, :port, 443)
    timeout = Keyword.get(opts, :timeout, 5_000)
    host = String.to_charlist(domain)

    connect_opts = [
      # See moduledoc: a bad cert is the finding, not a failure.
      verify: :verify_none,
      # SNI decides which cert Traefik serves, so it must be the domain we are asking
      # about — without it we would inspect whatever the default vhost returns.
      server_name_indication: host,
      active: false,
      versions: [:"tlsv1.2", :"tlsv1.3"]
    ]

    case tls_connect(Keyword.get(opts, :starttls), host, port, connect_opts, timeout) do
      {:ok, socket} ->
        result = read_peer_cert(socket, domain)
        :ssl.close(socket)
        result

      {:error, reason} ->
        {:error, {:handshake_failed, reason}}
    end
  end

  defp tls_connect(nil, host, port, connect_opts, timeout),
    do: :ssl.connect(host, port, connect_opts, timeout)

  # Postgres does not open with a TLS handshake. The client connects in plaintext, sends
  # an 8-byte SSLRequest, and only starts the handshake once the server answers `S` — so a
  # bare `:ssl.connect/4` tests a path no `libpq` client takes. Against a Traefik TCP route
  # that distinction is exactly what a probe should not paper over: Traefik answers the
  # SSLRequest ITSELF before muxing on the SNI name in the handshake that follows, so this
  # is the only way to find out whether a Postgres client would actually get through.
  #
  # `:ssl.connect/3` upgrades an already-connected socket, so everything after the
  # handshake — `read_peer_cert/2`, `describe/2` — is the same code the plain path uses.
  defp tls_connect(:postgres, host, port, connect_opts, timeout) do
    with {:ok, socket} <-
           :gen_tcp.connect(host, port, [:binary, active: false, packet: :raw], timeout),
         :ok <- :gen_tcp.send(socket, <<8::32, 80_877_103::32>>),
         {:ok, "S"} <- :gen_tcp.recv(socket, 1, timeout) do
      case :ssl.connect(socket, connect_opts, timeout) do
        {:ok, ssl_socket} ->
          {:ok, ssl_socket}

        {:error, reason} ->
          :gen_tcp.close(socket)
          {:error, reason}
      end
    else
      # `N` is a well-formed refusal: the server understood the request and does not offer
      # TLS. Named separately because it means the route is reaching something that speaks
      # Postgres, which a generic socket error does not.
      {:ok, "N"} -> {:error, :starttls_refused}
      {:ok, _other} -> {:error, :not_postgres}
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_peer_cert(socket, domain) do
    case :ssl.peercert(socket) do
      {:ok, der} -> {:ok, describe(der, domain)}
      {:error, reason} -> {:error, {:no_peer_cert, reason}}
    end
  end

  defp describe(der, domain) do
    # Destructured rather than read by position. `OTPTBSCertificate` carries two optional
    # fields — `issuerUniqueID` and `subjectUniqueID` — between the public key and the
    # extensions, and both are `:asn1_NOVALUE` on essentially every certificate in
    # existence. So an index that lands on one of them does not raise and does not read
    # an empty list: it reads an atom, which a `case` on "is this a list" then discards
    # as "no extensions". Naming the fields is what makes that class of miss impossible.
    {:OTPTBSCertificate, _version, _serial, _signature, issuer_rdn, validity, subject_rdn,
     _public_key, _issuer_uid, _subject_uid, extensions} =
      elem(:public_key.pkix_decode_cert(der, :otp), 1)

    {:Validity, _not_before, not_after_asn1} = validity

    issuer = rdn_common_name(issuer_rdn)
    subject = rdn_common_name(subject_rdn)
    not_after = parse_time(not_after_asn1)

    sans = subject_alt_names(extensions)
    names = Enum.uniq([subject | sans]) |> Enum.reject(&(&1 == ""))

    self_signed? = issuer == subject or String.contains?(issuer, @traefik_default)
    covers? = Enum.any?(names, &name_matches?(&1, domain))

    days = DateTime.diff(not_after, DateTime.utc_now(), :day)

    %{
      status: status(self_signed?, covers?, days),
      issuer: issuer,
      subject: subject,
      sans: sans,
      not_after: not_after,
      days_remaining: days,
      self_signed?: self_signed?,
      covers_domain?: covers?
    }
  end

  # Ordered by how badly the operator needs to know. A self-signed cert is the
  # headline failure — the browser refuses it — and it is the exact thing Traefik
  # falls back to when ACME could not issue for a custom domain.
  defp status(true, _covers?, _days), do: :self_signed
  defp status(_self, false, _days), do: :name_mismatch
  defp status(_self, _covers?, days) when days < 0, do: :expired
  defp status(_self, _covers?, days) when days <= @expiring_within_days, do: :expiring
  defp status(_self, _covers?, _days), do: :valid

  # A wildcard cert (*.homelab.example.com) covers one label, and only one. Compared
  # case-insensitively like the exact match below: DNS names are case-insensitive, and
  # the two halves of a name come from different places — the parent from the issued
  # certificate, the label from a Host rule an operator typed.
  defp name_matches?("*." <> wildcard_base, domain) do
    case String.split(domain, ".", parts: 2) do
      [_label, rest] -> String.downcase(rest) == String.downcase(wildcard_base)
      _ -> false
    end
  end

  defp name_matches?(name, domain), do: String.downcase(name) == String.downcase(domain)

  defp rdn_common_name({:rdnSequence, rdns}) do
    rdns
    |> List.flatten()
    |> Enum.find_value("", fn
      {:AttributeTypeAndValue, {2, 5, 4, 3}, value} -> decode_string(value)
      _ -> nil
    end)
  end

  defp rdn_common_name(_), do: ""

  # Common-name values arrive as DER-tagged strings ({:utf8String, "..."}, etc.) or,
  # for some encodings, as a raw charlist we have to strip the tag bytes off.
  defp decode_string({_type, value}) when is_binary(value), do: value
  defp decode_string({_type, value}) when is_list(value), do: List.to_string(value)

  defp decode_string(value) when is_binary(value) do
    case :public_key.der_decode(:X520CommonName, value) do
      {_type, decoded} when is_binary(decoded) -> decoded
      {_type, decoded} when is_list(decoded) -> List.to_string(decoded)
      _ -> value
    end
  rescue
    _ -> value
  end

  defp decode_string(value) when is_list(value), do: List.to_string(value)
  defp decode_string(_), do: ""

  # The SANs are where a certificate's real coverage lives. A Let's Encrypt leaf names
  # its first domain in the common name and EVERY name it authenticates in this
  # extension — so a host served off a wildcard (`lidarr.homelab.example.com` on a cert
  # whose CN is `homelab.example.com`) is covered here and nowhere else. Reading the
  # common name alone would call every such host a name mismatch.
  #
  # `:asn1_NOVALUE` when the certificate carries no extensions at all.
  defp subject_alt_names(extensions) when is_list(extensions) do
    extensions
    |> Enum.find_value([], fn
      {:Extension, {2, 5, 29, 17}, _critical, values} -> values
      _ -> nil
    end)
    |> Enum.flat_map(fn
      {:dNSName, name} -> [List.to_string(name)]
      _ -> []
    end)
  rescue
    _ -> []
  end

  defp subject_alt_names(_extensions), do: []

  defp parse_time({:utcTime, time}), do: parse_utc(List.to_string(time))
  defp parse_time({:generalTime, time}), do: parse_general(List.to_string(time))
  defp parse_time(_), do: DateTime.from_unix!(0)

  # "260712090000Z" — two-digit year, per RFC 5280 pivoting on 50.
  defp parse_utc(<<yy::binary-2, rest::binary>>) do
    year = String.to_integer(yy)
    century = if year >= 50, do: 1900, else: 2000
    parse_general("#{century + year}#{rest}")
  end

  defp parse_general(
         <<y::binary-4, m::binary-2, d::binary-2, h::binary-2, min::binary-2, s::binary-2,
           _rest::binary>>
       ) do
    %DateTime{
      year: String.to_integer(y),
      month: String.to_integer(m),
      day: String.to_integer(d),
      hour: String.to_integer(h),
      minute: String.to_integer(min),
      second: String.to_integer(s),
      time_zone: "Etc/UTC",
      zone_abbr: "UTC",
      utc_offset: 0,
      std_offset: 0
    }
  end

  defp parse_general(_), do: DateTime.from_unix!(0)
end
