defmodule Homelab.Networking.TlsProbeStub do
  @moduledoc """
  Stands in for `Homelab.Networking.TlsProbe` in tests, so mounting a deployment page
  does not open a real TLS connection to the internet.

  The probe runs inside a Task, which does NOT inherit the caller's process
  dictionary, so the staged result is read from the application env. Tests that stage
  a specific certificate must therefore be `async: false`. The default is a healthy
  certificate, which is what the vast majority of page-mounting tests want.
  """

  def inspect_domain(domain, _opts \\ []) do
    Application.get_env(:homelab, :tls_probe_result, :healthy)
    |> resolve(domain)
  end

  # A map stages a different answer per name, which is what a page probing a whole
  # table of domains needs — one wildcard-covered subdomain next to an apex domain
  # Traefik is serving its default certificate for. Names left out fall back to healthy.
  defp resolve(staged, domain) when is_map(staged) and not is_struct(staged) do
    staged |> Map.get(domain, :healthy) |> resolve(domain)
  end

  # `:public_key.pkix_decode_cert/2` raises on a certificate it cannot parse, and a
  # caller observing every domain on the box has to survive one of those.
  defp resolve(:raise, domain), do: raise(ArgumentError, "cannot decode #{domain}")

  defp resolve(:healthy, domain), do: {:ok, healthy(domain)}
  defp resolve(:wildcard, domain), do: {:ok, wildcard(domain)}
  defp resolve(:self_signed, _domain), do: {:ok, self_signed()}
  defp resolve({:error, _} = error, _domain), do: error
  defp resolve(result, _domain), do: result

  def healthy(domain) do
    %{
      status: :valid,
      issuer: "Let's Encrypt R3",
      subject: domain,
      sans: [domain],
      not_after: DateTime.add(DateTime.utc_now(), 60, :day),
      days_remaining: 60,
      self_signed?: false,
      covers_domain?: true,
      matched_name: domain
    }
  end

  @doc """
  A trusted certificate that covers `domain` through a wildcard rather than by name —
  the common case on a homelab box, where one `*.<base>` cert fronts every subdomain.
  """
  def wildcard(domain) do
    wildcard_name =
      case String.split(domain, ".", parts: 2) do
        [_label, rest] -> "*." <> rest
        _ -> "*." <> domain
      end

    %{
      healthy(domain)
      | subject: wildcard_name,
        sans: [wildcard_name],
        matched_name: wildcard_name
    }
  end

  # What Traefik actually serves when ACME never issued a certificate for the name.
  def self_signed do
    %{
      status: :self_signed,
      issuer: "TRAEFIK DEFAULT CERT",
      subject: "TRAEFIK DEFAULT CERT",
      sans: [],
      not_after: DateTime.add(DateTime.utc_now(), 365, :day),
      days_remaining: 365,
      self_signed?: true,
      covers_domain?: false,
      matched_name: nil
    }
  end
end
