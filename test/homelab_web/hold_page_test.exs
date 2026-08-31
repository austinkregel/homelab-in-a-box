defmodule HomelabWeb.HoldPageTest do
  @moduledoc """
  The page itself, as opposed to the decision to serve it (`HoldingPageTest`).
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Deployment
  alias HomelabWeb.HoldPage

  @states [
    :setting_up,
    :updating,
    :starting,
    :offline,
    :unavailable,
    :retired,
    :unknown,
    :control_plane
  ]

  # Every deployment status has to land somewhere, including one added later: a state
  # this module has no clause for raises at request time, on a host that is already
  # having a bad day.
  test "every deployment status maps to a state" do
    for status <- Ecto.Enum.values(Deployment, :status) do
      state = HoldPage.state_for(%Deployment{status: status})
      assert state in @states, "status #{status} produced #{inspect(state)}"
    end

    assert HoldPage.state_for(nil) == :unknown
  end

  test "every state renders, with copy and a status code" do
    for state <- @states do
      assert %{title: title, headline: headline, message: message} = HoldPage.copy(state)
      assert title != "" and headline != "" and message != ""
      assert HoldPage.http_status(state) in [404, 503]
      # The page escapes what it renders, and half this copy has an apostrophe in it.
      assert HoldPage.render_html(state, "app.example.com") =~
               String.replace(headline, "'", "&#39;")
    end
  end

  describe "state_for/1" do
    # `last_reconciled_at` is the only field that survives the reset a redeploy writes,
    # which is what makes "first time" distinguishable from "again" at all.
    test "a deploy of something that has never run is setting up" do
      assert HoldPage.state_for(%Deployment{status: :deploying}) == :setting_up
      assert HoldPage.state_for(%Deployment{status: :pending}) == :setting_up
    end

    test "a deploy of something that has run before is an update" do
      assert HoldPage.state_for(%Deployment{
               status: :deploying,
               last_reconciled_at: DateTime.utc_now()
             }) == :updating

      # An adopted container has an id before it has ever been reconciled.
      assert HoldPage.state_for(%Deployment{status: :deploying, external_id: "abc"}) == :updating
    end

    # If the row says running and the request still reached us, the container is up and
    # nothing is listening on it yet — the boot window, not a healthy app.
    test "running means the container is up but not answering" do
      assert HoldPage.state_for(%Deployment{status: :running}) == :starting
    end
  end

  test "only the states that are expected to end keep polling" do
    for state <- @states do
      html = HoldPage.render_html(state, "app.example.com")
      polls? = html =~ "/_hiab/hold/status.json"

      assert polls? == state in HoldPage.transient_states(),
             "#{state} polls?=#{polls?}"
    end

    refute :unknown in HoldPage.transient_states()
    refute :retired in HoldPage.transient_states()
  end

  describe "the status-code table" do
    # Each of these is a page in its own right, so each needs copy, a mark and a code --
    # and the code the page ANSWERS with has to be the code that asked for it, or a
    # visitor gets a teapot's body under some other status.
    test "every code renders a page that answers with that same code" do
      for {code, state} <- HoldPage.codes() do
        assert %{headline: headline} = HoldPage.copy(state)
        assert HoldPage.http_status(state) == String.to_integer(code)

        assert HoldPage.render_html(state, "app.example.com") =~
                 String.replace(headline, "'", "&#39;")
      end
    end

    test "covers the jokes and the ones a real deployment can produce" do
      codes = HoldPage.codes()

      assert codes["418"] == :teapot
      assert codes["420"] == :calm
      # A homelab runs out of disk and loops a redirect more often than it brews coffee.
      assert codes["507"] == :out_of_space
      assert codes["508"] == :loop
      assert codes["401"] == :sign_in
      assert codes["403"] == :forbidden
    end

    # 502 is the middleware's own callback and is answered from the HOST -- the page
    # says which kind of wait this is, which a status code cannot know. And 404 stays
    # out: an app's own 404 means it answered, which is not this page's business.
    test "leaves the codes that are answered from the host alone" do
      assert HoldPage.state_for_code("502") == nil
      assert HoldPage.state_for_code("404") == nil
      assert HoldPage.state_for_code("503") == nil
      assert HoldPage.state_for_code("nonsense") == nil
    end

    test "none of them poll -- a substituted response is not a wait" do
      for {_code, state} <- HoldPage.codes() do
        refute state in HoldPage.transient_states()
        refute HoldPage.render_html(state, "app.example.com") =~ "status.json"
      end
    end
  end

  # The host comes off a request header, and it is the one value on the page that is not
  # a constant.
  test "the host is escaped, not interpolated" do
    html = HoldPage.render_html(:offline, ~s|evil.com"><script>alert(1)</script>|)

    refute html =~ "<script>alert"
    assert html =~ "&lt;script&gt;"
  end

  # The page reloads itself when a response stops carrying this marker; the endpoint
  # and the script have to agree on it exactly.
  test "the poll body carries the marker the page looks for" do
    assert HoldPage.status_json(:updating) =~ ~s("hiab_hold":true)
    assert HoldPage.render_html(:updating, "app.example.com") =~ ~s('"hiab_hold":true')
  end
end
