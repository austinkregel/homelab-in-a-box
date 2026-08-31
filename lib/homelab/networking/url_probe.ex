defmodule Homelab.Networking.UrlProbe do
  @moduledoc """
  Asks the question a browser asks: does `https://<domain>/` answer, and is the thing
  answering the APP?

  `TlsProbe` establishes that a certificate is served for a name; this establishes that
  a request over that connection reaches the workload. The two are genuinely different
  outcomes — a TLS handshake completes perfectly against a Traefik that has no route to
  anything, which is exactly the window between "container replaced" and "router
  rebuilt".

  ## Telling our own hold page apart from the app

  A 502 during a deploy is not served as a 502: `HomelabWeb.Plugs.HoldingPage` answers
  Traefik's error callback with an interstitial, so the naive check ("did we get a
  response?") is satisfied by the page that exists *because* the app is down. Every hold
  response carries `x-hiab-hold: <state>`, and that header is the discriminator. Nothing
  else is reliable: the hold page deliberately returns a normal-looking status, and its
  body is styled to be indistinguishable from a real page at a glance.

  ## Any answer from the app counts

  `served_by: :app` is reported for 401, 403, 404 and 500 alike. The question is whether
  the routing chain — DNS, TLS, router, backend — carries a request to the workload, and
  every one of those proves it does. An `sso_protected` app answers the anonymous probe
  with a redirect to the identity provider; an app that serves nothing at `/` answers
  404. Requiring 200 would fail both, and both are correctly deployed.

  Redirects are deliberately NOT followed for the same reason: the 302 is the proof, and
  following it would leave us reporting on the identity provider's availability instead.

  ## Certificates are not verified here

  `verify: :verify_none`, matching `TlsProbe` — a cert that does not verify is a finding
  to report, not a reason to refuse to look. The caller pairs this with `TlsProbe` when
  it wants the certificate's own verdict; refusing the connection here would collapse
  "bad certificate" and "nothing is listening" into one indistinguishable error.
  """

  @type served_by :: :app | :hold

  @type result :: %{
          url: String.t(),
          status: non_neg_integer(),
          served_by: served_by(),
          hold_state: String.t() | nil
        }

  @hold_header "x-hiab-hold"
  @default_timeout 5_000

  @doc """
  Requests `https://<domain>/` and reports what answered.

  Returns `{:error, reason}` when no HTTP response could be obtained at all — the name
  does not resolve, nothing is listening, the connection times out. That is a distinct
  outcome from a hold page, and callers rely on the distinction: the first usually means
  DNS or the proxy, the second always means the app.
  """
  @spec reach(String.t(), keyword()) :: {:ok, result()} | {:error, term()}
  def reach(domain, opts \\ []) when is_binary(domain) do
    url = Keyword.get(opts, :url) || "https://#{domain}/"
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    request =
      Req.new(
        url: url,
        method: :get,
        # A probe must never queue behind Req's default retry schedule: the caller is
        # already a polling loop with a deadline, and retrying inside each poll would
        # multiply the interval by an amount the deadline does not know about.
        retry: false,
        redirect: false,
        receive_timeout: timeout,
        connect_options: [
          timeout: timeout,
          transport_opts: [verify: :verify_none]
        ]
      )

    case Req.request(request) do
      {:ok, %Req.Response{} = response} -> {:ok, describe(url, response)}
      {:error, reason} -> {:error, reason}
    end
  rescue
    # Req raises on some transport failures rather than returning them, and a probe that
    # raises would fail its release step as an exception instead of as "not reachable
    # yet" — which is the ordinary state for most of a deploy.
    e -> {:error, e}
  end

  defp describe(url, %Req.Response{status: status} = response) do
    case Req.Response.get_header(response, @hold_header) do
      [state | _] ->
        %{url: url, status: status, served_by: :hold, hold_state: state}

      [] ->
        %{url: url, status: status, served_by: :app, hold_state: nil}
    end
  end
end
