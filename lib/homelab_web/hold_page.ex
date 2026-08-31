defmodule HomelabWeb.HoldPage do
  @moduledoc """
  The interstitial pages served on a deployment's own hostname while there is nothing
  there to answer — "we're deploying", "we're updating", "try again in a few minutes".

  Two things are load-bearing here, and both are about what the page must NOT do.

  It must not leak. A hold page is served on a domain whose app is, by definition, not
  running — which means the exposure middleware that normally guards that host is gone
  with the container's labels (see `Homelab.Deployments.SpecBuilder`), so an
  `:sso_protected` app's hold page is reachable by anyone who resolves the name. Nothing
  here may therefore name the app, its image, its ports, its tenant, or its error: the
  only deployment-derived thing on the page is which of a handful of fixed states it is
  in, and the hostname the visitor already typed. `copy/1` is a lookup table of constants
  for exactly that reason — there is no interpolation point to leak through.

  It must not depend on the asset pipeline. The page is rendered by
  `HomelabWeb.Plugs.HoldingPage`, which sits in front of `Plug.Static` precisely so that
  a request for `/assets/app.css` on a held host is held too rather than being answered
  with the control plane's stylesheet. So everything the page needs — layout, colours,
  the mark, the poll script — is inline in the one response.

  The states, and what puts a visitor on each:

    * `:setting_up`  — first deploy, no container has ever run for this deployment.
    * `:updating`    — a redeploy of something that has run before.
    * `:starting`    — the container is up but not answering yet (Traefik's 502 window).
    * `:offline`     — deliberately stopped.
    * `:unavailable` — the last deploy failed.
    * `:retired`     — being removed; nothing will come back at this address.
    * `:unknown`     — a name under the wildcard with no deployment behind it at all.
    * `:control_plane` — the error page for the plane's OWN domain, which the entrypoint
      middleware also covers. Deliberately says nothing about a deployment, because on
      that host there isn't one.
  """

  alias Homelab.Deployments.Deployment

  @transient [:setting_up, :updating, :starting, :offline, :unavailable]

  @doc """
  The state to render for the deployment behind a held hostname, or `:unknown` when
  the name resolves to no deployment.

  `:running` maps to `:starting` rather than to anything reassuring: if the row says
  running and the request still reached US, the container exists but is not answering
  on its routed port — which is the boot window, not a healthy app.
  """
  @spec state_for(Deployment.t() | nil) :: atom()
  def state_for(nil), do: :unknown
  def state_for(%Deployment{status: :removing}), do: :retired
  def state_for(%Deployment{status: :stopped}), do: :offline
  def state_for(%Deployment{status: :failed}), do: :unavailable
  def state_for(%Deployment{status: :running}), do: :starting

  def state_for(%Deployment{status: status} = deployment) when status in [:pending, :deploying] do
    if first_deploy?(deployment), do: :setting_up, else: :updating
  end

  def state_for(%Deployment{}), do: :unavailable

  # `last_reconciled_at` is only ever SET (`Deployment.reconciled_changeset/1`), never
  # cleared, so it survives the `status: :pending` reset a redeploy writes — which is
  # what makes "have we ever been up?" answerable at all. `external_id` is checked
  # alongside it for a deployment adopted into the plane, which has a container before
  # it has ever been reconciled.
  defp first_deploy?(%Deployment{last_reconciled_at: nil, external_id: nil}), do: true
  defp first_deploy?(%Deployment{}), do: false

  # The status codes that name their own page, rather than being answered from whatever
  # the host turns out to be. Every one of these is a response a reverse-proxied app can
  # really produce -- plus the two that were written as jokes and outlived most of the
  # serious codes published beside them.
  #
  # 404 is deliberately absent. A 404 from an app means the app ANSWERED and the path
  # was wrong, which is the app's business; the host-level `:unknown` is a different
  # thing and already covers a name with nothing behind it.
  @codes %{
    "400" => :bad_request,
    "401" => :sign_in,
    "403" => :forbidden,
    "413" => :too_large,
    "418" => :teapot,
    "420" => :calm,
    "429" => :rate_limited,
    "500" => :app_error,
    "504" => :timeout,
    "507" => :out_of_space,
    "508" => :loop
  }

  @state_codes Map.new(@codes, fn {code, state} -> {state, String.to_integer(code)} end)

  @doc """
  The state a status code in the hold path names, or nil for a code that is answered
  from the host instead.

  The error middleware calls back at `/_hiab/hold/{status}`, so the outcome is named in
  the path: one endpoint carries a page per outcome, and every one of them is reachable
  on purpose at `https://<any held host>/_hiab/hold/507`.

  Only 502 and 504 arrive here on their own today (see
  `Homelab.Infrastructure.hold_ingress_yaml/2`). The rest are wired by adding the code
  to that middleware's `status` list, which is a deliberate act rather than a default:
  substituting our page for an app's own 401 or 500 hides a real answer from whoever
  was waiting on it, and for 418 and 420 it would replace a joke somebody meant.
  """
  @spec state_for_code(String.t()) :: atom() | nil
  def state_for_code(code), do: Map.get(@codes, code)

  @doc "The status-code -> state table these pages are addressed by."
  @spec codes() :: %{String.t() => atom()}
  def codes, do: @codes

  @doc "Every state whose page should keep polling, because it is expected to end."
  def transient_states, do: @transient

  @doc """
  The fixed copy for a state. No deployment values reach this map — see the moduledoc.
  """
  @spec copy(atom()) :: %{title: String.t(), headline: String.t(), message: String.t()}
  def copy(:setting_up),
    do: %{
      title: "Setting up",
      headline: "We're setting this up",
      message: "This service is being deployed for the first time. It should be here shortly."
    }

  def copy(:updating),
    do: %{
      title: "Updating",
      headline: "We're updating",
      message: "This service is being updated right now. It'll be back in a moment."
    }

  def copy(:starting),
    do: %{
      title: "Starting",
      headline: "Almost there",
      message: "This service is starting up and isn't answering yet. Give it a few seconds."
    }

  def copy(:offline),
    do: %{
      title: "Offline",
      headline: "This service is offline",
      message: "It isn't running at the moment. Please try again later."
    }

  def copy(:unavailable),
    do: %{
      title: "Unavailable",
      headline: "Temporarily unavailable",
      message: "This service isn't answering right now. Please try again in a few minutes."
    }

  def copy(:retired),
    do: %{
      title: "Not available",
      headline: "Nothing here any more",
      message: "This address is no longer serving anything."
    }

  def copy(:unknown),
    do: %{
      title: "Not found",
      headline: "Nothing is published here",
      message: "No service answers at this address."
    }

  def copy(:bad_request),
    do: %{
      title: "Bad request",
      headline: "That request didn't make sense",
      message:
        "Something about it was malformed, so the server couldn't read it. " <>
          "If you typed or pasted the address, it's worth a second look."
    }

  def copy(:sign_in),
    do: %{
      title: "Sign in required",
      headline: "You'll need to sign in",
      message: "This service is behind a sign-in, and this browser doesn't have a session yet."
    }

  def copy(:forbidden),
    do: %{
      title: "Not permitted",
      headline: "Not allowed from here",
      message:
        "This service only answers requests from certain networks, and this one isn't " <>
          "on the list."
    }

  def copy(:too_large),
    do: %{
      title: "Too large",
      headline: "That's bigger than this accepts",
      message: "The file or form you sent is over this service's size limit. Try a smaller one."
    }

  def copy(:rate_limited),
    do: %{
      title: "Too many requests",
      headline: "That's a lot of requests",
      message:
        "They're arriving faster than this service will take them. " <>
          "Wait a moment and try again."
    }

  def copy(:app_error),
    do: %{
      title: "Application error",
      headline: "The app hit an error",
      message:
        "It's running and it answered — something inside it just went wrong handling " <>
          "that request."
    }

  def copy(:timeout),
    do: %{
      title: "Timed out",
      headline: "This is taking too long",
      message:
        "The service took the request but didn't finish answering in time. " <>
          "It may simply be busy."
    }

  def copy(:out_of_space),
    do: %{
      title: "Out of space",
      headline: "The box is out of room",
      message:
        "There's no storage left to finish that. Someone with a key will need to make some."
    }

  def copy(:loop),
    do: %{
      title: "Redirect loop",
      headline: "This is going in circles",
      message:
        "The request keeps being sent back to where it started, so the server stopped " <>
          "following it."
    }

  def copy(:teapot),
    do: %{
      title: "I'm a teapot",
      headline: "This one's a teapot",
      message:
        "Short and stout, no coffee, and nothing else for you either. " <>
          "Whatever you were after, it is in another pot."
    }

  def copy(:calm),
    do: %{
      title: "Enhance your calm",
      headline: "Enhance your calm",
      message: "That was a lot of requests very quickly. Breathe out; try again in a minute."
    }

  def copy(:control_plane),
    do: %{
      title: "Unavailable",
      headline: "Something went wrong",
      message: "Homelab-in-a-Box couldn't complete that request. Please try again shortly."
    }

  @doc """
  The status code for a page served on the CATCH-ALL path.

  503 for everything a visitor should come back to, so a monitor, a crawler and a
  browser cache all read the outage as an outage — a 200 here would have uptime
  checks reporting a held app as healthy. 404 only where nothing is coming back.

  The error-middleware path does not use this: there, Traefik keeps the upstream's
  own status and takes only our body.
  """
  @spec http_status(atom()) :: pos_integer()
  def http_status(state) when is_map_key(@state_codes, state), do: Map.fetch!(@state_codes, state)
  def http_status(state) when state in [:retired, :unknown], do: 404
  def http_status(_state), do: 503

  @doc "`Retry-After`, in seconds, or nil where there is nothing to come back for."
  @spec retry_after(atom()) :: pos_integer() | nil
  def retry_after(state) when state in [:setting_up, :updating, :starting], do: 10
  def retry_after(state) when state in [:offline, :unavailable, :control_plane], do: 60
  # The two the visitor can actually act on by waiting, as opposed to by fixing.
  def retry_after(state) when state in [:calm, :rate_limited], do: 60
  def retry_after(:timeout), do: 30
  def retry_after(_state), do: nil

  @doc """
  The JSON body of the poll endpoint.

  `hiab_hold` is the marker the page's own script looks for: any response WITHOUT it
  means Traefik is no longer routing this host to us, i.e. the app is back, and the
  page reloads itself. That is deliberately a body marker rather than a header — the
  error middleware reproduces our body but is not required to reproduce our headers.
  """
  @spec status_json(atom()) :: String.t()
  def status_json(state) do
    ~s({"hiab_hold":true,"state":"#{state}","transient":#{state in @transient}})
  end

  @doc """
  The page. `host` is echoed back only because the visitor typed it; it is escaped
  regardless, since it arrives in a request header.
  """
  @spec render_html(atom(), String.t()) :: String.t()
  def render_html(state, host) do
    %{title: title, headline: headline, message: message} = copy(state)
    host = escape(host)
    transient? = state in @transient
    # The sweep says "something is happening right now", so only the states where
    # something IS say it. `:offline` and `:unavailable` still poll — they just do it
    # quietly, because nothing is working on them and a moving bar would imply otherwise.
    in_flight? = state in [:setting_up, :updating, :starting]

    """
    <!DOCTYPE html>
    <html lang="en">
    <head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <meta name="robots" content="noindex, nofollow">
    <title>#{escape(title)} · #{host}</title>
    <style>#{styles()}#{accent_css(state)}</style>
    </head>
    <body>
    <main class="card">
      <div class="mark" aria-hidden="true">#{mark(state)}</div>
      <p class="pill"><span class="dot#{if in_flight?, do: " live", else: ""}"></span>#{escape(title)}</p>
      <h1>#{escape(headline)}</h1>
      <p class="message">#{escape(message)}</p>
      <p class="host"><span class="host-dot"></span>#{host}</p>
      #{if in_flight?, do: bar(), else: ""}
      <p class="foot">#{wordmark()}Homelab-in-a-Box</p>
    </main>
    #{if transient?, do: poll_script(), else: ""}
    </body>
    </html>
    """
  end

  # The whole visual identity, inline. Both colour schemes are defined as variables and
  # switched by `prefers-color-scheme`, because a hold page is the one page in the system
  # that cannot ask the control plane what theme the operator picked.
  #
  # Everything that varies by STATE is a variable set by `accent_css/1` instead, so a
  # page announcing a deploy and a page announcing a failure are the same layout wearing
  # different colours rather than two things to keep in step.
  defp styles do
    """
    :root{color-scheme:light dark;
    --bg:#f5f7fb;--card:#fff;--ink:#0f131c;--muted:#5b6478;--line:#e5e9f2;--chip:#f8fafd;
    --dot:rgba(15,19,28,.07);--shadow:0 24px 60px -32px rgba(16,24,40,.45)}
    @media (prefers-color-scheme:dark){:root{
    --bg:#11141c;--card:#1a1e28;--ink:#eef1f8;--muted:#98a2b8;--line:#282e3b;--chip:#151922;
    --dot:rgba(255,255,255,.045);--shadow:0 24px 60px -28px rgba(0,0,0,.75)}}
    *{box-sizing:border-box}
    body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;padding:28px;
    color:var(--ink);background-color:var(--bg);
    background-image:radial-gradient(60rem 32rem at 50% -14rem,var(--accent-glow),transparent 70%),
    radial-gradient(circle at 1px 1px,var(--dot) 1px,transparent 0);
    background-size:auto,22px 22px;
    font:16px/1.55 ui-sans-serif,system-ui,-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;
    -webkit-font-smoothing:antialiased}
    .card{position:relative;overflow:hidden;width:100%;max-width:33rem;padding:44px 36px 32px;text-align:center;
    background:var(--card);border:1px solid var(--line);border-radius:20px;box-shadow:var(--shadow)}
    /* A hairline of the state's own colour along the top edge: the first thing that says
       which kind of page this is, before a word has been read. */
    .card::before{content:"";position:absolute;top:0;left:0;right:0;height:1px;
    background:linear-gradient(90deg,transparent,var(--accent),transparent);opacity:.9}
    .mark{position:relative;margin:0 auto 22px;width:84px;height:84px;color:var(--accent);
    animation:float 4.5s ease-in-out infinite}
    .mark::after{content:"";position:absolute;inset:-18%;border-radius:50%;
    background:radial-gradient(circle,var(--accent-glow),transparent 68%);z-index:-1}
    .mark svg{width:100%;height:100%;display:block}
    .lid{transform-origin:50% 60%;animation:lift 3.4s ease-in-out infinite}
    .face{fill:var(--accent);fill-opacity:.14}
    .sand{fill-opacity:.34}
    @keyframes float{0%,100%{transform:translateY(0)}50%{transform:translateY(-5px)}}
    @keyframes lift{0%,100%{transform:translateY(0)}50%{transform:translateY(-8%)}}
    .pill{display:inline-flex;align-items:center;gap:7px;margin:0 0 16px;padding:5px 13px 5px 10px;
    border-radius:999px;background:var(--accent-soft);color:var(--accent);
    font-size:.7rem;font-weight:650;letter-spacing:.1em;text-transform:uppercase}
    .dot{width:6px;height:6px;border-radius:50%;background:currentColor;flex:none}
    .dot.live{animation:blink 1.8s ease-in-out infinite}
    @keyframes blink{0%,100%{opacity:1;box-shadow:0 0 0 0 var(--accent-soft)}
    50%{opacity:.45;box-shadow:0 0 0 5px transparent}}
    h1{margin:0 0 12px;font-size:1.75rem;line-height:1.2;font-weight:680;letter-spacing:-.021em}
    .message{margin:0 auto;max-width:27rem;color:var(--muted);font-size:1.02rem}
    .host{display:inline-flex;align-items:center;gap:9px;margin:26px 0 0;padding:8px 14px;
    border:1px solid var(--line);border-radius:11px;background:var(--chip);color:var(--muted);
    font:.83rem/1.3 ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;word-break:break-all}
    .host-dot{width:5px;height:5px;border-radius:50%;background:var(--accent);flex:none}
    .bar{position:relative;overflow:hidden;margin:26px auto 0;width:min(13rem,70%);height:2px;
    border-radius:2px;background:var(--line)}
    .bar::after{content:"";position:absolute;inset:0;border-radius:2px;
    background:linear-gradient(90deg,transparent,var(--accent),transparent);animation:sweep 2s ease-in-out infinite}
    @keyframes sweep{0%{transform:translateX(-100%)}100%{transform:translateX(100%)}}
    .foot{display:flex;align-items:center;justify-content:center;gap:7px;margin:34px 0 0;
    font-size:.74rem;font-weight:550;letter-spacing:.05em;color:var(--muted);opacity:.7}
    .foot svg{width:15px;height:15px;display:block;opacity:.9}
    /* The two marks that are not the box. */
    .steam{transform-origin:50% 70%;animation:steam 3.4s ease-in-out infinite}
    .steam-b{animation-delay:.9s}
    @keyframes steam{0%,100%{opacity:.2;transform:translateY(1px)}50%{opacity:.95;transform:translateY(-2.5px)}}
    .ring{transform-origin:50% 50%;animation:breathe 5.5s ease-in-out infinite;opacity:.45}
    .ring-2{animation-delay:.4s;opacity:.7}
    @keyframes breathe{0%,100%{transform:scale(.88)}50%{transform:scale(1.06)}}
    @media (max-width:420px){.card{padding:34px 22px 26px}h1{font-size:1.5rem}}
    @media (prefers-reduced-motion:reduce){
    .mark,.lid,.dot.live,.bar::after,.steam,.ring{animation:none}}
    """
  end

  # One colour per state, in both schemes. Amber for a thing that is mid-flight, rose for
  # a thing that went wrong, slate for a thing that is simply not there -- a visitor who
  # has seen one of these before knows which kind it is from across the room.
  defp accent_css(state) do
    {light, dark} = accent(state)

    """
    :root{--accent:#{light};--accent-soft:#{tint(light, "0.11")};--accent-glow:#{tint(light, "0.13")}}
    @media (prefers-color-scheme:dark){:root{--accent:#{dark};
    --accent-soft:#{tint(dark, "0.14")};--accent-glow:#{tint(dark, "0.10")}}}
    """
  end

  defp accent(:setting_up), do: {"#4f46e5", "#9d9bf8"}
  defp accent(:updating), do: {"#6d28d9", "#b79cff"}
  defp accent(:starting), do: {"#b45309", "#f0b45c"}
  defp accent(:teapot), do: {"#0e7490", "#67e8f9"}
  defp accent(:calm), do: {"#15803d", "#86efac"}
  # Sky for the two that are about WHO is asking rather than about the server.
  defp accent(state) when state in [:sign_in, :forbidden], do: {"#0369a1", "#7dd3fc"}
  # Amber for a request the visitor can change and send again.
  defp accent(state) when state in [:bad_request, :too_large, :rate_limited],
    do: {"#b45309", "#f0b45c"}

  # Rose for the ones where the server is what went wrong.
  defp accent(state) when state in [:app_error, :timeout, :out_of_space, :loop],
    do: {"#be123c", "#fb8098"}

  defp accent(state) when state in [:unavailable, :control_plane], do: {"#be123c", "#fb8098"}
  defp accent(_state), do: {"#475569", "#94a3b8"}

  # `#rrggbb` -> `rgba(r,g,b,a)`, so one accent constant can also be its own wash.
  defp tint("#" <> hex, alpha) do
    [r, g, b] = for <<pair::binary-2 <- hex>>, do: String.to_integer(pair, 16)
    "rgba(#{r},#{g},#{b},#{alpha})"
  end

  # A teapot, for the one status code that was written as a joke and outlived every
  # serious thing published beside it.
  defp mark(:teapot) do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <path class="steam" d="M20 10c1.7-1.7-1.7-3.4 0-5.1"/>
    <path class="steam steam-b" d="M28 10c1.7-1.7-1.7-3.4 0-5.1"/>
    <path class="face" d="M13 21h22v2.5c0 6.4-4.9 11-11 11s-11-4.6-11-11z" stroke="none"/>
    <path d="M13 21h22v2.5c0 6.4-4.9 11-11 11s-11-4.6-11-11z"/>
    <path d="M17.4 21c.9-3.3 3.4-5.2 6.6-5.2s5.7 1.9 6.6 5.2"/>
    <path d="M24 15.8v-2"/>
    <path d="M13 23.5c-4.2.2-6.4-1.6-7.7-5"/>
    <path d="M35 23c3.5.2 5.3 2 5.3 4.2s-1.9 3.9-4.4 4"/>
    </svg>
    """
  end

  # Concentric rings on a slow breath. The joke is in the words; the mark just has to
  # do what the words ask.
  defp mark(:calm) do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round">
    <circle class="ring" cx="24" cy="24" r="18"/>
    <circle class="ring ring-2" cx="24" cy="24" r="12.5"/>
    <circle class="face" cx="24" cy="24" r="7"/>
    </svg>
    """
  end

  # Who is asking, rather than what is wrong: sign-in and the IP allowlist.
  defp mark(state) when state in [:sign_in, :forbidden] do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M16.5 20.5V16a7.5 7.5 0 0 1 15 0v4.5"/>
    <rect class="face" x="11" y="20.5" width="26" height="19" rx="4" stroke="none"/>
    <rect x="11" y="20.5" width="26" height="19" rx="4"/>
    <path d="M24 27.5v5.5"/>
    </svg>
    """
  end

  # Waiting on time, one way or the other: too fast, or too slow.
  defp mark(state) when state in [:rate_limited, :timeout] do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M13 7h22M13 41h22"/>
    <path class="face sand" d="M18 35.5c0-3.6 6-7 6-7s6 3.4 6 7z" stroke="none"/>
    <path d="M16.5 7v4.6c0 4.3 7.5 8 7.5 12.4s-7.5 8.1-7.5 12.4V41"/>
    <path d="M31.5 7v4.6c0 4.3-7.5 8-7.5 12.4s7.5 8.1 7.5 12.4V41"/>
    </svg>
    """
  end

  # Platters, because this is the one error on the list that is about the disk.
  defp mark(:out_of_space) do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <ellipse class="face" cx="24" cy="13" rx="13" ry="5" stroke="none"/>
    <ellipse cx="24" cy="13" rx="13" ry="5"/>
    <path d="M11 13v10c0 2.8 5.8 5 13 5s13-2.2 13-5V13"/>
    <path d="M11 23v10c0 2.8 5.8 5 13 5s13-2.2 13-5V23"/>
    </svg>
    """
  end

  # The shape of the problem itself.
  defp mark(:loop) do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <g transform="translate(24 24) scale(1.55) translate(-24 -24)" stroke-width="1.3">
    <path d="M17 17a7 7 0 1 0 0 14c5 0 7-14 14-14a7 7 0 1 1 0 14c-7 0-9-14-14-14z"/>
    </g>
    </svg>
    """
  end

  # The box, mid-unpack: the lid lifts off a tinted top face. It is the "in a box" half
  # of the name, and the one thing on the page that is unmistakably this project.
  defp mark(_state) do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="2" \
    stroke-linecap="round" stroke-linejoin="round">
    <path d="M7 14 24 22 41 14 24 6z" class="face lid" stroke-width="2"/>
    <path d="M7 14v20l17 8 17-8V14" />
    <path d="M24 22v20" />
    <path d="M7 14 24 22 41 14" stroke-opacity=".55"/>
    </svg>
    """
  end

  defp wordmark do
    """
    <svg viewBox="0 0 48 48" fill="none" stroke="currentColor" stroke-width="3" \
    stroke-linejoin="round" aria-hidden="true">
    <path d="M7 14 24 6l17 8v20l-17 8-17-8z"/>
    </svg>
    """
  end

  defp bar, do: ~s(<div class="bar" role="presentation"></div>)

  # Polls the hold endpoint on THIS host and reloads the moment the answer stops being
  # ours — which is exactly the moment Traefik starts routing the host to the app again,
  # so the visitor lands on the real thing without touching anything. Backs off, and
  # gives up after half an hour rather than polling a dead tab forever.
  defp poll_script do
    """
    <script>
    (function(){
      var started = Date.now();
      function again(){
        var age = Date.now() - started;
        if (age > 1800000) return;
        setTimeout(check, age > 120000 ? 15000 : 5000);
      }
      function check(){
        fetch("/_hiab/hold/status.json", {cache:"no-store", credentials:"omit"})
          .then(function(r){ return r.text(); })
          .then(function(body){
            if (body.indexOf('"hiab_hold":true') === -1) { location.reload(); } else { again(); }
          })
          .catch(again);
      }
      again();
    })();
    </script>
    """
  end

  defp escape(value) do
    value
    |> to_string()
    |> String.replace("&", "&amp;")
    |> String.replace("<", "&lt;")
    |> String.replace(">", "&gt;")
    |> String.replace("\"", "&quot;")
    |> String.replace("'", "&#39;")
  end
end
