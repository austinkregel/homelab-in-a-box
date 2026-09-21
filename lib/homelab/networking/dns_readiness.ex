defmodule Homelab.Networking.DnsReadiness do
  @moduledoc """
  Answers one question: does this name exist in public DNS yet?

  It gates the ACME resolver. A domain registered minutes ago is delegated to its
  nameservers on the registrar's schedule, not ours, and until that lands Let's
  Encrypt cannot validate anything for it — the DNS-01 TXT record is written into a
  zone no resolver is being sent to. Traefik retries regardless, and Let's Encrypt
  caps **failed validations at 5 per hour per hostname**, so a box pointed at a
  not-yet-delegated domain spends its budget overnight and is then still rate-limited
  for hours after DNS is finally ready. Holding ACME back until the name resolves is
  what turns "wait a day and it works" into something that converges.

  ## Why "resolves at all" and not "resolves to us"

  The stricter check — does the A record point at one of `Networking.host_addresses/0`
  — is wrong for most of the installs this is for. Behind NAT the public record holds
  the router's WAN address while this container holds an RFC1918 one, so the two never
  match and the gate would never open. That is a permanent loss of TLS to prevent a
  transient rate-limit, which is the wrong trade.

  Resolving at all is the real precondition: it proves the zone is delegated and being
  served, which is exactly what the DNS-01 TXT record needs in order to be seen.

  ## Failing open

  Every ambiguous outcome is treated as ready. A resolver timeout, a SERVFAIL, a
  container with no working resolver of its own — none of those prove the domain is
  absent, and a false negative here means no certificate ever. The only answer that
  holds the gate shut is an authoritative "this name has no address".
  """

  require Logger

  @timeout 2_000

  @doc """
  True when `domain` has an address record in public DNS, or when we cannot tell.

  A blank domain is not ready: there is nothing to ask about, and requesting a
  certificate for it would fail on a malformed identifier rather than on propagation.

  Overridable with `config :homelab, :dns_readiness_check, true | false | fun/1` so a
  test never reaches for a resolver, and an operator who knows better than the check
  can state the answer outright.
  """
  @spec resolves?(String.t() | nil) :: boolean()
  def resolves?(domain) do
    case Application.get_env(:homelab, :dns_readiness_check) do
      answer when is_boolean(answer) -> answer
      fun when is_function(fun, 1) -> fun.(domain)
      _ -> lookup(domain)
    end
  end

  defp lookup(domain) when is_binary(domain) do
    case String.trim(domain) do
      "" -> false
      trimmed -> any_address?(String.to_charlist(trimmed))
    end
  end

  defp lookup(_domain), do: false

  # `:inet_res.lookup/5` returns [] both for "no such name" and for "the resolver never
  # answered", which is the distinction this gate turns on. `:inet_res.resolve/5` keeps
  # the failure reason, so ask it and read the outcome rather than the list.
  defp any_address?(host) do
    resolved?(host, :a) or resolved?(host, :aaaa)
  end

  defp resolved?(host, type) do
    case :inet_res.resolve(host, :in, type, [], @timeout) do
      {:ok, record} ->
        :inet_dns.msg(record, :anlist) != []

      # NXDOMAIN: authoritative, and the one answer that means "not yet".
      {:error, {:nxdomain, _}} ->
        false

      {:error, :nxdomain} ->
        false

      # Everything else — timeout, SERVFAIL, no nameservers configured in this
      # container — is us being unable to see, not the domain being absent.
      {:error, reason} ->
        Logger.debug(
          "DnsReadiness: #{type} lookup for #{host} was inconclusive (#{inspect(reason)}); " <>
            "treating the domain as ready"
        )

        true
    end
  end
end
