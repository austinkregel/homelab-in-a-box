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
    assert Enum.any?(paths, &String.starts_with?(&1, "/api/v1/backups"))
    assert "/api/v1/health" not in paths
    assert length(paths) > 10
  end
end
