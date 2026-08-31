defmodule HomelabWeb.Plugs.HoldingPageTest do
  @moduledoc """
  A deployment's route lives on its own container's labels, so between "the container is
  gone" and "the container answers" there is no route at all and Traefik replies 404 —
  on a domain the operator has handed out. These tests drive the ENDPOINT rather than
  the plug module, because the feature is "what does a browser get on this hostname",
  and the plug's position in the endpoint (in front of `Plug.Static`) is part of the
  answer.

  The half that matters most is the pass-through: the same endpoint serves the control
  plane's UI, and a host-matching mistake here does not degrade a page, it takes the
  operator's only way back in and replaces it with an apology.
  """
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory

  @base "lab.test.local"

  setup do
    previous = Application.get_env(:homelab, :base_domain)
    Application.put_env(:homelab, :base_domain, @base)
    on_exit(fn -> Application.put_env(:homelab, :base_domain, previous) end)
    :ok
  end

  defp held?(conn), do: get_resp_header(conn, "x-hiab-hold") != []
  defp hold_state(conn), do: conn |> get_resp_header("x-hiab-hold") |> List.first()

  defp deployment(attrs) do
    insert(:deployment, Keyword.merge([domain: "app.#{@base}", status: :deploying], attrs))
  end

  describe "hosts the plane answers for itself" do
    test "the base domain reaches the control plane, not a hold page", %{conn: conn} do
      conn = get(conn, "https://#{@base}/")

      refute held?(conn)
      assert conn.status == 200
    end

    # The Quick Start in the readme is `-p 4000:4000` and a browser at localhost, which
    # has no base domain in it at all. A host the plane does not route is not the plane's
    # to hold.
    test "localhost reaches the control plane", %{conn: conn} do
      conn = get(conn, "http://localhost:4000/")

      refute held?(conn)
      assert conn.status == 200
    end

    test "an unrelated hostname is left alone", %{conn: conn} do
      conn = get(conn, "https://box.tailnet.example.org/")

      refute held?(conn)
      assert conn.status == 200
    end

    # An operator who routes an app AT the base domain has a Traefik problem; they must
    # not also lose the UI to it.
    test "a deployment routed at the base domain does not hold the plane's own host", %{
      conn: conn
    } do
      deployment(domain: @base, status: :failed)

      conn = get(conn, "https://#{@base}/")

      refute held?(conn)
      assert conn.status == 200
    end
  end

  describe "a deployment's own hostname" do
    test "a first deploy is setting up", %{conn: conn} do
      deployment(status: :deploying, external_id: nil, last_reconciled_at: nil)

      conn = get(conn, "https://app.#{@base}/")

      assert conn.status == 503
      assert hold_state(conn) == "setting_up"
      assert conn.resp_body =~ "We&#39;re setting this up"
      assert get_resp_header(conn, "retry-after") == ["10"]
    end

    # The distinction the operator asked for: a redeploy of something that has been up
    # says "updating", and only a genuinely new deployment says "setting up".
    test "a redeploy of something that has run before is updating", %{conn: conn} do
      deployment(status: :deploying, last_reconciled_at: DateTime.utc_now())

      conn = get(conn, "https://app.#{@base}/")

      assert hold_state(conn) == "updating"
      assert conn.resp_body =~ "We&#39;re updating"
    end

    test "a running deployment we are still being asked about is starting", %{conn: conn} do
      deployment(status: :running, external_id: "abc123")

      conn = get(conn, "https://app.#{@base}/")

      assert hold_state(conn) == "starting"
      assert conn.resp_body =~ "Almost there"
    end

    test "a stopped deployment is offline, and says nothing about coming back soon", %{conn: conn} do
      deployment(status: :stopped)

      conn = get(conn, "https://app.#{@base}/")

      assert conn.status == 503
      assert hold_state(conn) == "offline"
      assert get_resp_header(conn, "retry-after") == ["60"]
    end

    test "a failed deployment asks for a retry rather than reporting a failure", %{conn: conn} do
      deployment(status: :failed, error_message: "OCI runtime create failed: no such file")

      conn = get(conn, "https://app.#{@base}/")

      assert hold_state(conn) == "unavailable"
      assert conn.resp_body =~ "try again in a few minutes"
    end

    # `additional_domains` becomes a Traefik router exactly like `domain` does
    # (SpecBuilder.additional_domain_labels/2), so it goes dark exactly like one too.
    test "a host alias is held as well as the primary domain", %{conn: conn} do
      deployment(
        domain: "matrix.#{@base}",
        additional_domains: [%{"host" => "chat.#{@base}"}]
      )

      conn = get(conn, "https://chat.#{@base}/")

      assert held?(conn)
      assert conn.resp_body =~ "chat.#{@base}"
    end

    test "a domain outside the base domain is still held", %{conn: conn} do
      deployment(domain: "aut.hair", status: :stopped)

      conn = get(conn, "https://aut.hair/")

      assert held?(conn)
      assert hold_state(conn) == "offline"
    end
  end

  describe "names with nothing behind them" do
    test "an unclaimed name under the wildcard is a 404, not a maybe", %{conn: conn} do
      conn = get(conn, "https://nothing.#{@base}/")

      assert conn.status == 404
      assert hold_state(conn) == "unknown"
      assert get_resp_header(conn, "retry-after") == []
    end

    test "a deployment being removed does not promise to come back", %{conn: conn} do
      deployment(status: :removing)

      conn = get(conn, "https://app.#{@base}/")

      assert conn.status == 404
      assert hold_state(conn) == "retired"
    end
  end

  describe "the whole host is held, not just its root path" do
    # In front of Plug.Static on purpose. A browser rendering a held site asks for its
    # stylesheet next, and answering that with the control plane's asset is both the
    # wrong bytes and a small disclosure that something else lives here.
    test "a static asset path on a held host gets the hold page", %{conn: conn} do
      deployment(status: :deploying)

      conn = get(conn, "https://app.#{@base}/assets/css/app.css")

      assert held?(conn)
      assert conn.status == 503
      refute conn.resp_body =~ "tailwind"
    end

    test "a deep path on a held host gets the hold page", %{conn: conn} do
      deployment(status: :deploying)

      conn = get(conn, "https://app.#{@base}/settings/profile?tab=2")

      assert held?(conn)
      assert conn.status == 503
    end
  end

  describe "the error middleware's callback" do
    # Traefik keeps the UPSTREAM's status code and substitutes only our body, so a 503
    # here would change nothing for the client -- and since the middleware covers this
    # endpoint too, it would send our own page back through the proxy to re-render.
    test "answers 200 so Traefik can keep the upstream's status", %{conn: conn} do
      deployment(status: :running, external_id: "abc123")

      conn = get(conn, "https://app.#{@base}/_hiab/hold/502")

      assert conn.status == 200
      assert hold_state(conn) == "starting"
      assert conn.resp_body =~ "Almost there"
    end

    test "on the plane's own host it claims no deployment", %{conn: conn} do
      conn = get(conn, "https://#{@base}/_hiab/hold/502")

      assert hold_state(conn) == "control_plane"
      assert conn.resp_body =~ "Homelab-in-a-Box couldn&#39;t complete that request"
    end
  end

  # Every one of these is a response a proxied app can really produce, so each gets a
  # page of its own rather than the generic "we're deploying". They are reachable on
  # purpose -- the code is in the path the error middleware already calls back on.
  describe "pages named by a status code" do
    test "a code answers with its own page and its own status", %{conn: conn} do
      deployment(status: :running)

      conn = get(conn, "https://app.#{@base}/_hiab/hold/507")

      assert conn.status == 507
      assert hold_state(conn) == "out_of_space"
      assert conn.resp_body =~ "out of room"
    end

    test "the jokes are in there too", %{conn: conn} do
      teapot = get(conn, "https://app.#{@base}/_hiab/hold/418")

      assert teapot.status == 418
      assert teapot.resp_body =~ "teapot"

      calm = get(conn, "https://app.#{@base}/_hiab/hold/420")

      assert calm.status == 420
      assert calm.resp_body =~ "Enhance your calm"
      assert get_resp_header(calm, "retry-after") == ["60"]
    end

    # The code describes what happened to the REQUEST; the host describes which app. A
    # code that names a page therefore beats the host, even where the host would have
    # had something to say.
    test "a named code wins over the deployment behind the host", %{conn: conn} do
      deployment(status: :deploying)

      conn = get(conn, "https://app.#{@base}/_hiab/hold/401")

      assert hold_state(conn) == "sign_in"
      refute conn.resp_body =~ "setting this up"
    end

    # 502 is the middleware's own callback: there the host is the only thing that knows
    # whether this is a first deploy, an update or a restart.
    test "an unnamed code is still answered from the host, with 200", %{conn: conn} do
      deployment(status: :deploying, last_reconciled_at: DateTime.utc_now())

      conn = get(conn, "https://app.#{@base}/_hiab/hold/502")

      assert conn.status == 200
      assert hold_state(conn) == "updating"
    end

    # The pages are worth looking at while building the box, which is where the box is
    # reached by a name that is not routed at all.
    test "they are reachable on any host, including localhost", %{conn: conn} do
      conn = get(conn, "http://localhost:4000/_hiab/hold/508")

      assert conn.status == 508
      assert hold_state(conn) == "loop"
    end
  end

  describe "the poll endpoint" do
    # The page reloads itself when a response STOPS carrying this marker, which is the
    # moment Traefik has a real route again. Anything that changes the marker breaks
    # every held page's ability to notice it is over.
    test "carries the marker the page watches for", %{conn: conn} do
      deployment(status: :deploying)

      conn = get(conn, "https://app.#{@base}/_hiab/hold/status.json")

      assert conn.status == 200
      assert conn.resp_body =~ ~s("hiab_hold":true)
      assert conn.resp_body =~ ~s("transient":true)
    end

    test "is not cacheable, on any hold response", %{conn: conn} do
      deployment(status: :deploying)

      conn = get(conn, "https://app.#{@base}/")

      assert get_resp_header(conn, "cache-control") == ["no-store, no-cache, must-revalidate"]
      assert get_resp_header(conn, "x-robots-tag") == ["noindex, nofollow"]
    end
  end

  # The reason the copy is a table of constants. This page is served on a host whose
  # exposure middleware went away with the container's labels, so an :sso_protected
  # app's hold page is readable by anyone who can resolve the name -- it may not say
  # what the app is, what it runs, whose space it is in, or how it broke.
  describe "what the page may not say" do
    test "names nothing about the deployment behind the host", %{conn: conn} do
      tenant = insert(:tenant, name: "Marketing Space", slug: "marketing-space")

      template =
        insert(:app_template,
          name: "Nextcloud Hub",
          slug: "nextcloud-hub",
          image: "nextcloud:29-apache"
        )

      insert(:deployment,
        domain: "app.#{@base}",
        status: :failed,
        tenant: tenant,
        app_template: template,
        external_id: "9f2c1ab44e01",
        error_message: "OCI runtime create failed: /data not found"
      )

      body = get(conn, "https://app.#{@base}/").resp_body

      for secret <- [
            "Nextcloud",
            "nextcloud",
            "29-apache",
            "Marketing",
            "marketing-space",
            "9f2c1ab44e01",
            "OCI runtime",
            "/data"
          ] do
        refute body =~ secret, "the hold page leaked #{inspect(secret)}"
      end

      assert body =~ "app.#{@base}"
    end
  end
end
