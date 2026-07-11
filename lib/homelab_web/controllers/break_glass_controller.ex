defmodule HomelabWeb.BreakGlassController do
  @moduledoc """
  Emergency, non-OIDC admin login (see `Homelab.Auth.BreakGlass`).

  When break-glass is not configured the routes 404 — the feature is invisible.
  When it is configured, `GET /auth/break-glass` renders a standalone token form
  and `POST` verifies it, logging a loud audit entry either way.

  The page is rendered as raw HTML (no app layout) on purpose: break-glass must
  work even when the rest of the app's assigns/session state can't be assumed.
  """
  use HomelabWeb, :controller

  require Logger

  alias Homelab.Accounts
  alias Homelab.Audit
  alias Homelab.Auth.BreakGlass

  plug :ensure_enabled

  def new(conn, _params), do: render_form(conn, nil)

  def create(conn, %{"token" => token}) when is_binary(token) do
    if BreakGlass.verify(token) do
      grant(conn)
    else
      deny(conn)
    end
  end

  def create(conn, _params), do: deny(conn)

  # --- internals ------------------------------------------------------------

  defp grant(conn) do
    case Accounts.get_or_create_breakglass_admin(BreakGlass.user_label()) do
      {:ok, user} ->
        Accounts.update_last_login(user)

        Audit.log("break_glass.login", "auth", nil,
          user_id: user.id,
          metadata: %{"ip" => client_ip(conn)}
        )

        Logger.warning("BREAK-GLASS login SUCCEEDED from #{client_ip(conn)} (user_id=#{user.id})")

        # One-time: burn the token now so it can never be reused. The session is
        # already being established, so even if the file removal fails the login
        # still completes (consume/0 logs loudly in that case).
        BreakGlass.consume()

        conn
        # Renew the session id on privilege grant, then attach the identity.
        |> configure_session(renew: true)
        |> put_session(:user_id, user.id)
        |> put_flash(:info, "Signed in via break-glass. Restore OIDC and rotate the token.")
        |> redirect(to: "/")

      {:error, _changeset} ->
        Logger.error("BREAK-GLASS: admin user could not be created")
        render_form(conn, "Break-glass admin could not be created. Check logs.")
    end
  end

  defp deny(conn) do
    Audit.log("break_glass.denied", "auth", nil, metadata: %{"ip" => client_ip(conn)})
    Logger.warning("BREAK-GLASS login DENIED from #{client_ip(conn)}")
    # Crude constant-cost throttle: a high-entropy token isn't feasibly
    # brute-forceable, but this removes any incentive to try in a tight loop.
    # Configurable so tests don't pay the second.
    Process.sleep(Application.get_env(:homelab, :breakglass_deny_delay_ms, 1_000))
    render_form(conn, "Invalid break-glass token.")
  end

  defp ensure_enabled(conn, _opts) do
    if BreakGlass.enabled?() do
      conn
    else
      conn
      |> put_resp_content_type("text/plain")
      |> send_resp(404, "Not found")
      |> halt()
    end
  end

  defp client_ip(conn) do
    case conn.remote_ip do
      ip when is_tuple(ip) -> ip |> :inet.ntoa() |> to_string()
      _ -> "unknown"
    end
  end

  defp render_form(conn, error) do
    csrf = Plug.CSRFProtection.get_csrf_token()
    conn |> put_resp_content_type("text/html") |> send_resp(status_for(error), page(csrf, error))
  end

  defp status_for(nil), do: 200
  defp status_for(_error), do: 401

  defp page(csrf, error) do
    error_html =
      case error do
        nil ->
          ""

        msg ->
          ~s(<p class="err">#{Phoenix.HTML.html_escape(msg) |> Phoenix.HTML.safe_to_string()}</p>)
      end

    """
    <!doctype html>
    <html lang="en">
    <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1">
      <title>Break-glass sign in</title>
      <style>
        :root { color-scheme: light dark; }
        body { font-family: system-ui, sans-serif; display: grid; place-items: center;
               min-height: 100vh; margin: 0; background: #0f172a; color: #e2e8f0; }
        .card { width: min(90vw, 22rem); padding: 2rem; border-radius: 12px;
                background: #1e293b; box-shadow: 0 10px 30px rgba(0,0,0,.4); }
        h1 { font-size: 1.15rem; margin: 0 0 .25rem; }
        p.sub { margin: 0 0 1.25rem; font-size: .85rem; color: #94a3b8; }
        label { display: block; font-size: .8rem; margin-bottom: .35rem; color: #cbd5e1; }
        input { width: 100%; box-sizing: border-box; padding: .6rem .7rem; border-radius: 8px;
                border: 1px solid #334155; background: #0f172a; color: #e2e8f0; font-size: 1rem; }
        button { width: 100%; margin-top: 1rem; padding: .65rem; border: 0; border-radius: 8px;
                 background: #ef4444; color: white; font-size: .95rem; font-weight: 600; cursor: pointer; }
        .err { color: #fca5a5; font-size: .85rem; margin: 0 0 1rem; }
        .warn { margin-top: 1.25rem; font-size: .75rem; color: #fbbf24; }
      </style>
    </head>
    <body>
      <main class="card">
        <h1>Break-glass sign in</h1>
        <p class="sub">Emergency access for when OIDC is unavailable.</p>
        #{error_html}
        <form method="post" action="/auth/break-glass">
          <input type="hidden" name="_csrf_token" value="#{csrf}">
          <label for="token">Break-glass token</label>
          <input id="token" name="token" type="password" autocomplete="off" autofocus required>
          <button type="submit">Sign in</button>
        </form>
        <p class="warn">This bypasses your identity provider. Every use is audited. Rotate the token after use.</p>
      </main>
    </body>
    </html>
    """
  end
end
