defmodule HomelabWeb.Plugs.HoldingPage do
  @moduledoc """
  Serves `HomelabWeb.HoldPage` for a request that reached the plane on some OTHER
  service's hostname — the "we're deploying, try again in a moment" interstitial that
  stands in for a 404 while an app is not there to answer.

  Two Traefik arrangements send us that traffic, and this plug is what both land on
  (see `Homelab.Infrastructure.hold_ingress_yaml/2`):

    * A catch-all router at priority 1 over `*.<base_domain>`, which only wins when the
      app's own router does not exist — a container that has not been created yet, is
      stopped, or failed. The request arrives with its original host and path.

    * An `errors` middleware on the websecure entrypoint, which re-issues the request
      to us at `/_hiab/hold/{status}` when an upstream answers 502/504. That is the
      window where the container is running but nothing is listening on the routed port
      yet, which no router-level trick can see.

  ## What it must not swallow

  The plane's own UI is served by this same endpoint, so the ordering below is the
  feature's whole safety argument. A request is held only when it is FOR a held host:
  a hostname a deployment is routed at, or a name under the wildcard with nothing behind
  it. Everything else — `base_domain`, `localhost:4000`, an IP, a tailnet name, whatever
  else an operator reaches the box by — falls through untouched, because "not a name we
  route" is the default rather than a case to be remembered.

  It sits in FRONT of `Plug.Static` deliberately. A held host asking for
  `/assets/app.css` is a browser rendering someone else's site, and answering it with
  the control plane's stylesheet would be both wrong and a small disclosure; the hold
  page carries its own styling for exactly this reason.
  """

  import Plug.Conn

  alias Homelab.Config
  alias Homelab.Deployments
  alias Homelab.Networking.Hostname
  alias HomelabWeb.HoldPage

  @prefix "/_hiab/hold"
  @status_path "/_hiab/hold/status.json"

  def init(opts), do: opts

  def call(%Plug.Conn{} = conn, _opts) do
    case disposition(conn) do
      :pass -> conn
      {:status_json, state} -> send_status_json(conn, state)
      {:page, state, status} -> send_page(conn, state, status)
    end
  end

  defp disposition(conn) do
    host = Hostname.normalize(conn.host)
    base = Hostname.normalize(Config.base_domain())
    path = conn.request_path

    cond do
      path == @status_path ->
        {:status_json, callback_state(host, base)}

      # The error middleware's callback, which arrives carrying the ORIGINAL host: the
      # middleware builds its sub-request as `http://<req.Host><query>` and copies the
      # request headers, so `conn.host` below is the app's hostname and not the proxy's
      # view of us. That is what lets one endpoint answer for every held domain.
      #
      String.starts_with?(path, @prefix) ->
        held_by_code(conn) || {:page, callback_state(host, base), 200}

      # The control plane's own host is never held. It is checked before the lookup so
      # that an app deliberately routed at the base domain cannot take the UI down with
      # it — and after the two paths above, which are addressed to us rather than to a
      # deployment.
      is_binary(base) and host == base ->
        :pass

      deployment = held_deployment(host) ->
        page(HoldPage.state_for(deployment))

      under_wildcard?(host, base) ->
        page(:unknown)

      true ->
        :pass
    end
  end

  # A code that names its own page (`HoldPage.state_for_code/1`) is answered with that
  # page AND with that code. Every one of them describes an outcome the host cannot: the
  # host says which app, the code says what happened to the request.
  #
  # Everything else is an ordinary middleware callback, and gets 200. Traefik wraps the
  # response writer so the client is given the UPSTREAM's status and only our BODY (our
  # headers do carry over), which makes the status we choose there invisible — while a
  # 503 would additionally be a status the middleware itself covers, sending our own
  # page back through the proxy to re-render itself.
  defp held_by_code(conn) do
    case conn.path_info do
      ["_hiab", "hold", code] ->
        case HoldPage.state_for_code(code) do
          nil -> nil
          state -> page(state)
        end

      _ ->
        nil
    end
  end

  # On the error-middleware path the host still decides what the visitor is looking at:
  # a deployment's domain gets that deployment's page, and the plane's own domain gets
  # the one page that mentions no deployment at all, because on that host there is none.
  defp callback_state(host, base) do
    cond do
      is_binary(base) and host == base -> :control_plane
      deployment = held_deployment(host) -> HoldPage.state_for(deployment)
      true -> :unknown
    end
  end

  defp held_deployment(nil), do: nil
  defp held_deployment(host), do: Deployments.get_deployment_by_hostname(host)

  # Mirrors the catch-all router's `HostRegexp(^.+\\.<base>$)`: anything under the base
  # domain is ours to answer for, whether or not a deployment claims it.
  defp under_wildcard?(host, base) when is_binary(host) and is_binary(base) do
    String.ends_with?(host, "." <> base)
  end

  defp under_wildcard?(_host, _base), do: false

  defp page(state), do: {:page, state, HoldPage.http_status(state)}

  defp send_page(conn, state, status) do
    conn
    |> hold_headers(state)
    |> put_resp_content_type("text/html")
    |> send_resp(status, HoldPage.render_html(state, conn.host))
    |> halt()
  end

  defp send_status_json(conn, state) do
    conn
    |> hold_headers(state)
    |> put_resp_content_type("application/json")
    |> send_resp(200, HoldPage.status_json(state))
    |> halt()
  end

  # `no-store` because the page outlives its own truth by seconds: a cached "we're
  # deploying" served after the app is back is worse than the outage was. `noindex`
  # because these hosts are public and a crawler that catches a deploy window must not
  # keep the interstitial as the site.
  defp hold_headers(conn, state) do
    conn
    |> put_resp_header("cache-control", "no-store, no-cache, must-revalidate")
    |> put_resp_header("x-robots-tag", "noindex, nofollow")
    |> put_resp_header("x-hiab-hold", to_string(state))
    |> maybe_retry_after(HoldPage.retry_after(state))
  end

  defp maybe_retry_after(conn, nil), do: conn

  defp maybe_retry_after(conn, seconds),
    do: put_resp_header(conn, "retry-after", to_string(seconds))
end
