defmodule Homelab.Networking.TlsObserver do
  @moduledoc """
  Records what each domain is actually serving, so the rest of the app can read it
  instead of asking.

  `TlsProbe` answers the question; this is what writes the answer down. The distinction
  matters because the answer has readers who must not each open their own handshake —
  the Domains page renders a row per domain, and a page that probed on every view would
  put 19 TLS connections on the box each time an operator glanced at the tab.

  So the observation is state, written on `CertManager`'s pass and on an explicit
  re-check, and every reader reads the row. `tls_checked_at` is part of the record
  rather than an afterthought: a stored status with no age cannot be presented honestly.

  ## What this does NOT write

  `domains.tls_status`, the lifecycle column the renewal loop drives off. An
  observation is what IS; that column is what we intend, and collapsing them would
  mean a domain serving Traefik's default certificate — which needs ACME to keep
  trying — became indistinguishable from one whose renewal errored. `CertManager` owns
  that column and uses these observations to decide what to do about it.
  """

  require Logger

  alias Homelab.Networking
  alias Homelab.Networking.Domain

  @doc """
  Observes every domain and records what it found, returning `%{fqdn => result}`.

  Concurrent with back-pressure: this is one handshake per domain against hosts that
  may not answer, and `inspect_domain/2` bounds each at 5s.
  """
  @spec observe_all() :: %{String.t() => {:ok, map()} | {:error, term()}}
  def observe_all do
    Networking.list_domains() |> observe()
  end

  @doc """
  Observes the named domains, skipping any with no `Domain` row to record against.

  Used by the Domains page's re-check, which knows fqdns rather than rows.
  """
  @spec observe_fqdns([String.t()]) :: %{String.t() => {:ok, map()} | {:error, term()}}
  def observe_fqdns(fqdns) do
    fqdns
    |> Enum.uniq()
    |> Enum.flat_map(fn fqdn ->
      case Networking.get_domain_by_fqdn(fqdn) do
        {:ok, domain} -> [domain]
        {:error, :not_found} -> []
      end
    end)
    |> observe()
  end

  defp observe(domains) do
    domains
    |> Task.async_stream(
      fn domain -> {domain.fqdn, observe_one(domain)} end,
      max_concurrency: 8,
      # Each probe bounds its own handshake, so the stream needs no deadline of its
      # own — and a killed task would drop a domain's observation silently.
      timeout: :infinity
    )
    |> Enum.reduce(%{}, fn {:ok, {fqdn, result}}, acc -> Map.put(acc, fqdn, result) end)
  end

  defp observe_one(%Domain{} = domain) do
    result =
      try do
        tls_probe().inspect_domain(domain.fqdn)
      rescue
        # `:public_key.pkix_decode_cert/2` raises on a certificate it cannot parse. One
        # unreadable certificate must not take down the pass for every other domain.
        error ->
          Logger.warning("TlsObserver: #{domain.fqdn} served an unreadable certificate")
          {:error, error}
      end

    record(domain, result)
    result
  end

  defp record(domain, result) do
    attrs =
      result
      |> observation()
      |> Map.put(:tls_checked_at, DateTime.utc_now() |> DateTime.truncate(:second))

    domain
    |> Domain.observation_changeset(attrs)
    |> Homelab.Repo.update()
    |> case do
      {:ok, updated} ->
        updated

      {:error, changeset} ->
        Logger.error("TlsObserver: could not record #{domain.fqdn}: #{inspect(changeset.errors)}")

        domain
    end
  end

  defp observation({:ok, probe}) do
    %{
      tls_observed_status: probe.status,
      tls_matched_name: probe.matched_name,
      tls_issuer: probe.issuer
    }
  end

  # A handshake that could not be completed at all is an observation too, and a more
  # useful one than "unknown": nothing is answering on :443 for this name.
  defp observation({:error, _reason}) do
    %{tls_observed_status: :unreachable, tls_matched_name: nil, tls_issuer: nil}
  end

  # The same seam `CertManager` and the deployment page read, so a test does not open a
  # real TLS connection to the internet.
  defp tls_probe, do: Application.get_env(:homelab, :tls_probe, Homelab.Networking.TlsProbe)
end
