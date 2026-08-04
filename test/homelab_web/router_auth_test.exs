defmodule HomelabWeb.RouterAuthTest do
  @moduledoc """
  Walks the REAL route table and asserts that every route which is not deliberately
  public refuses an anonymous request.

  This exists because `/api/v1` shipped with no authentication of any kind — the whole
  scope was `plug :accepts, ["json"]` and nothing else — and the test suite could not
  see it. `HomelabWeb.ConnCase` seeds `user_id` into every conn it builds, so all nine
  API test files were authenticated by accident and passed identically against an
  unprotected router.

  A per-endpoint test would have had the same blind spot for the NEXT route someone
  adds. This one enumerates `HomelabWeb.Router.__routes__/0`, so a new route is covered
  the moment it exists: either it refuses anonymous callers, or it is named below with a
  reason.
  """
  use HomelabWeb.ConnCase, async: false

  import Homelab.Factory

  # Routes that are public ON PURPOSE. Anything not listed here must refuse anonymous
  # requests; adding to this list is a deliberate act with a stated reason.
  @public_paths [
    # The setup wizard has to be reachable before there is anyone to log in as.
    "/setup",
    # OIDC handshake and break-glass. Locking these would lock everyone out.
    "/auth/oidc",
    "/auth/oidc/callback",
    "/auth/logout",
    "/auth/break-glass",
    # A container HEALTHCHECK and the post-deploy smoke test in PRODUCTION.md call this
    # before anyone could be logged in. It reveals per-service up/down and a version.
    "/api/v1/health",
    # Phoenix's own LiveView socket + static assets.
    "/live/websocket",
    "/live/longpoll"
  ]

  defp routes do
    HomelabWeb.Router.__routes__()
    |> Enum.filter(&(&1.verb in [:get, :post, :put, :patch, :delete]))
    |> Enum.reject(&(&1.path in @public_paths))
    # Dev-only tooling (LiveDashboard, mailbox) is not mounted in test.
    |> Enum.reject(&String.starts_with?(&1.path, "/dev"))
  end

  # `:id`/`:tenant_id` are filled with a value that will not exist. An authorization
  # check must run BEFORE the lookup, so "not found" is itself a failure here: it means
  # the anonymous caller got far enough to learn whether a record exists.
  defp concrete(path) do
    String.replace(path, ~r/:[a-z_]+/, "999999999")
  end

  test "every non-public route refuses an anonymous request" do
    offenders =
      for route <- routes(), reduce: [] do
        acc ->
          conn =
            unauthenticated_conn()
            |> put_req_header("accept", "application/json")

          result =
            try do
              conn = dispatch(conn, HomelabWeb.Endpoint, route.verb, concrete(route.path), %{})
              {:ok, conn.status}
            rescue
              # A crash is not an auth check, but it is also not a silent success — the
              # request did not reach a handler that could act on it.
              _ -> {:ok, :raised}
            catch
              :exit, _ -> {:ok, :exited}
            end

          case result do
            # 302 = redirected to login (browser pipeline). 401/403 = refused (API).
            {:ok, status} when status in [302, 401, 403] -> acc
            {:ok, :raised} -> acc
            {:ok, :exited} -> acc
            {:ok, status} -> [{route.verb, route.path, status} | acc]
          end
      end

    assert offenders == [],
           """
           These routes served an ANONYMOUS request instead of refusing it:

           #{Enum.map_join(offenders, "\n", fn {verb, path, status} -> "  #{verb |> to_string() |> String.upcase()} #{path} -> #{status}" end)}

           Either put them behind an auth pipeline, or add them to @public_paths in this
           file with a reason.
           """
  end

  test "the detection mechanism can see a 200 — it is not passing vacuously" do
    # `/api/v1/health` is deliberately public, so it answers 200 to the exact dispatch
    # the sweep uses. If that came back as a refusal, the sweep above would be asserting
    # nothing at all.
    conn =
      unauthenticated_conn()
      |> put_req_header("accept", "application/json")
      |> dispatch(HomelabWeb.Endpoint, :get, "/api/v1/health", %{})

    assert conn.status == 200
  end

  test "the sweep actually covers the API surface it was written for" do
    # Guards against the list above silently becoming empty (a router refactor, a
    # filter that over-matches) and the test passing vacuously.
    paths = Enum.map(routes(), & &1.path)

    assert Enum.any?(paths, &String.starts_with?(&1, "/api/v1/tenants"))
    assert Enum.any?(paths, &(&1 =~ ~r{^/api/v1/tenants/[^/]+/backups}))

    # F10: backups were top-level and unscoped, so any logged-in user could restore any
    # tenant's snapshot. Re-adding a top-level route would reinstate that bypass whether
    # or not the nested one still exists, so pin its absence rather than only asserting
    # the nested route is present.
    refute Enum.any?(paths, &String.starts_with?(&1, "/api/v1/backups"))

    assert "/api/v1/health" not in paths
    assert length(paths) > 10
  end

  # --- Administrator vs. member ---------------------------------------------------
  #
  # `users.role` shipped as an enum that nothing enforced, so every signed-in user was
  # an administrator. The gate that fixes that has the same failure mode this file was
  # written for, one rung up: `test/support/factory.ex` defaults `role: :admin`, so
  # every `insert(:user)` in the suite is an administrator and NOTHING that uses the
  # ConnCase conn can observe a member being refused. Authenticated-by-accident became
  # admin-by-accident. Everything below drives a genuine `:member`.

  # Routes an administrator may reach and a member may not. Write, or privilege.
  @admin_routes [
    # Where privilege is granted, where the IdP is pointed, where auth can be switched
    # off — and the endpoint that dumps the whole configuration.
    {:get, "/settings"},
    {:get, "/settings/export"},
    # These end in running a container image on the Docker host.
    {:get, "/workbench"},
    {:get, "/deploy/new"},
    # Where a space and its deployments are edited and destroyed.
    {:get, "/tenants/:id"},
    # Every mutating API route. `POST .../deployments` reaches `deploy_now/1` and
    # `image_override` takes any parseable reference; `DELETE` destroys real
    # infrastructure; `restore` overwrites live data from a snapshot.
    {:post, "/api/v1/tenants"},
    {:patch, "/api/v1/tenants/:id"},
    {:put, "/api/v1/tenants/:id"},
    {:delete, "/api/v1/tenants/:id"},
    {:post, "/api/v1/tenants/:tenant_id/deployments"},
    {:patch, "/api/v1/tenants/:tenant_id/deployments/:id"},
    {:put, "/api/v1/tenants/:tenant_id/deployments/:id"},
    {:delete, "/api/v1/tenants/:tenant_id/deployments/:id"},
    {:post, "/api/v1/tenants/:tenant_id/backups"},
    {:post, "/api/v1/tenants/:tenant_id/backups/:id/restore"}
  ]

  # Routes a member may reach. Read-only: they render state, and none of them is where
  # privilege is granted or the box is changed.
  @member_routes [
    {:get, "/"},
    {:get, "/catalog"},
    {:get, "/deployments/:id"},
    {:get, "/domains"},
    {:get, "/backups"},
    {:get, "/activity"},
    {:get, "/telemetry"},
    {:get, "/api/v1/tenants"},
    {:get, "/api/v1/tenants/:id"},
    {:get, "/api/v1/tenants/:tenant_id/deployments"},
    {:get, "/api/v1/tenants/:tenant_id/deployments/:id"},
    {:get, "/api/v1/tenants/:tenant_id/backups"},
    {:get, "/api/v1/tenants/:tenant_id/backups/:id"},
    {:get, "/api/v1/app-templates"},
    {:get, "/api/v1/app-templates/:id"}
  ]

  # A REAL member. `HomelabWeb.ConnCase` is frozen and its conn is an admin, so this is
  # local — the same shape as its own `unauthenticated_conn/0`, and for the same reason:
  # reach for it whenever the thing under test is *whether* something is restricted.
  defp member_conn do
    member = insert(:user, role: :member)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, member.id)
  end

  defp admin_conn do
    admin = insert(:user, role: :admin)

    Phoenix.ConnTest.build_conn()
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session(:user_id, admin.id)
  end

  # The browser pipeline runs `:accepts, ["html"]` before anything else, so asking a
  # browser route for JSON is a 406 and never reaches the gate.
  defp accept_for(conn, "/api/" <> _), do: put_req_header(conn, "accept", "application/json")
  defp accept_for(conn, _path), do: put_req_header(conn, "accept", "text/html")

  defp attempt(conn, verb, path) do
    conn = accept_for(conn, path)

    try do
      {:ok, dispatch(conn, HomelabWeb.Endpoint, verb, concrete(path), %{})}
    rescue
      e -> {:raised, e}
    catch
      :exit, _ -> {:exited, nil}
    end
  end

  # The admin gate's two refusals, and only those: `RequireAdmin`'s flash + redirect, or
  # `RequireAdminApi`'s 403.
  #
  # Matched on the FLASH, not just "302 to /". Several LiveViews redirect to "/" of
  # their own accord when the record in the path does not exist — `/tenants/:id` does —
  # and a sweep that counted those as refusals would report an administrator being
  # turned away from a route they can perfectly well reach.
  @admin_refusal "That area is restricted to administrators."

  defp refused_as_non_admin?({:ok, conn}) do
    cond do
      conn.status == 403 -> true
      conn.status == 302 -> conn.assigns[:flash]["error"] == @admin_refusal
      true -> false
    end
  end

  defp refused_as_non_admin?(_), do: false

  test "every administrator-only route refuses a member" do
    offenders =
      for {verb, path} <- @admin_routes,
          result = attempt(member_conn(), verb, path),
          not refused_as_non_admin?(result) do
        {verb, path, describe_result(result)}
      end

    assert offenders == [],
           """
           These administrator-only routes served a MEMBER instead of refusing:

           #{format_offenders(offenders)}

           Browser routes must redirect to "/" (RequireAdmin); API routes must answer
           403 (RequireAdminApi).
           """
  end

  test "no member route is refused by the admin gate" do
    # The other half. A gate that refuses everyone passes a refusal-only test, and
    # locking members out of the read-only views is the failure mode the whole
    # admin/member split was chosen to avoid.
    offenders =
      for {verb, path} <- @member_routes,
          result = attempt(member_conn(), verb, path),
          refused_as_non_admin?(result) do
        {verb, path, describe_result(result)}
      end

    assert offenders == [],
           """
           These routes are supposed to be readable by a member and were refused:

           #{format_offenders(offenders)}
           """
  end

  test "an administrator reaches the routes a member is refused" do
    # Proves the refusals above are about the ROLE and not about the route being broken.
    offenders =
      for {verb, path} <- @admin_routes,
          result = attempt(admin_conn(), verb, path),
          refused_as_non_admin?(result) do
        {verb, path, describe_result(result)}
      end

    assert offenders == [],
           """
           These administrator-only routes refused an ADMINISTRATOR:

           #{format_offenders(offenders)}
           """
  end

  test "a member actually gets served — the sweeps are not passing on crashes" do
    # `/` is the plainest member route there is. If this were a 302 or a raise, "not
    # refused by the admin gate" would be true of everything and the sweep above would
    # be asserting nothing.
    conn =
      member_conn()
      |> put_req_header("accept", "text/html")
      |> dispatch(HomelabWeb.Endpoint, :get, "/", %{})

    assert conn.status == 200
  end

  test "every non-public route is classified as either administrator-only or member" do
    # Forces a decision on the NEXT route someone adds: it lands in neither list and
    # this fails, rather than silently defaulting to whatever pipeline it was pasted
    # into. Same argument as the anonymous sweep above, for authorization.
    classified = MapSet.new(@admin_routes ++ @member_routes)

    unclassified =
      for route <- routes(),
          not MapSet.member?(classified, {route.verb, route.path}),
          do: {route.verb, route.path, "unclassified"}

    assert unclassified == [],
           """
           These routes are behind authentication but nothing says whether a member may
           use them:

           #{format_offenders(unclassified)}

           Add each to @admin_routes or @member_routes in this file.
           """

    # And the reverse: a list that outlives the route it names is a test asserting
    # nothing, so neither list may contain a route the router does not have.
    live_routes = MapSet.new(routes(), &{&1.verb, &1.path})
    assert MapSet.subset?(classified, live_routes)
  end

  defp describe_result({:ok, conn}), do: "#{conn.status}"
  defp describe_result({:raised, e}), do: "raised #{inspect(e.__struct__)}"
  defp describe_result({:exited, _}), do: "exited"

  defp format_offenders(offenders) do
    Enum.map_join(offenders, "\n", fn {verb, path, detail} ->
      "  #{verb |> to_string() |> String.upcase()} #{path} -> #{detail}"
    end)
  end
end
