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
    case Application.get_env(:homelab, :tls_probe_result, :healthy) do
      :healthy -> {:ok, healthy(domain)}
      :self_signed -> {:ok, self_signed()}
      {:error, _} = error -> error
      result -> result
    end
  end

  def healthy(domain) do
    %{
      status: :valid,
      issuer: "Let's Encrypt R3",
      subject: domain,
      sans: [domain],
      not_after: DateTime.add(DateTime.utc_now(), 60, :day),
      days_remaining: 60,
      self_signed?: false,
      covers_domain?: true
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
      covers_domain?: false
    }
  end
end
