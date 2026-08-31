defmodule Homelab.Networking.UrlProbeStub do
  @moduledoc """
  Stands in for `Homelab.Networking.UrlProbe` in tests, so running a routed release does
  not send a real HTTPS request to whatever `deployment.domain` happens to say.

  That matters more than the TLS stub it mirrors: `verify_public_url` is planned on every
  routed release, the factory's domains are made-up names, and without this every such
  test would make a live request to one — slow when it times out, and occasionally
  worse when the name resolves to something real.

  Staged through the application env rather than the process dictionary, matching
  `TlsProbeStub`: the release runner may probe from a task, which does not inherit the
  caller's dictionary. Tests that stage a result must therefore be `async: false`.

  The default is the app answering 200, which is what almost every test wants — a
  release that reaches `:running` with its URL verified.
  """

  def reach(domain, opts \\ []) do
    url = Keyword.get(opts, :url) || "https://#{domain}/"

    case Application.get_env(:homelab, :url_probe_result, :answered) do
      :answered -> {:ok, answered(url)}
      :holding -> {:ok, holding(url)}
      {:error, _} = error -> error
      result -> result
    end
  end

  @doc "The app itself answered — the routing chain works end to end."
  def answered(url, status \\ 200) do
    %{url: url, status: status, served_by: :app, hold_state: nil}
  end

  @doc """
  Our own interstitial answered, which is the state a naive probe mistakes for success:
  a perfectly normal-looking response that exists precisely because the app is not up.
  """
  def holding(url, state \\ "updating") do
    %{url: url, status: 503, served_by: :hold, hold_state: state}
  end
end
