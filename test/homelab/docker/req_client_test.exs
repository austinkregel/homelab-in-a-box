defmodule Homelab.Docker.ReqClientTest do
  # Exercises the real Docker transport's request-shaping and error-mapping logic
  # against a Bypass (TCP) server, without a Docker daemon. async: false because
  # it toggles global app env + the persistent_term version cache.
  use ExUnit.Case, async: false

  alias Homelab.Docker.ReqClient

  setup do
    bypass = Bypass.open()
    Application.put_env(:homelab, ReqClient, base_url: "http://localhost:#{bypass.port}")
    ReqClient.reset_api_version_cache()

    on_exit(fn ->
      Application.delete_env(:homelab, ReqClient)
      ReqClient.reset_api_version_cache()
    end)

    {:ok, bypass: bypass}
  end

  # Req only decodes the body to a term when the response is JSON-typed.
  defp json(conn, status, data) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.resp(status, Jason.encode!(data))
  end

  # Stubs the version-negotiation endpoint so the first request can proceed.
  defp stub_version(bypass, version \\ "1.47") do
    Bypass.stub(bypass, "GET", "/version", fn conn ->
      json(conn, 200, %{"ApiVersion" => version})
    end)
  end

  describe "API version negotiation" do
    test "prefixes requests with the negotiated version and caches it", %{bypass: bypass} do
      version_hits = :counters.new(1, [])

      Bypass.expect(bypass, "GET", "/version", fn conn ->
        :counters.add(version_hits, 1, 1)
        json(conn, 200, %{"ApiVersion" => "1.47"})
      end)

      Bypass.expect(bypass, "GET", "/v1.47/containers/json", fn conn ->
        json(conn, 200, [])
      end)

      assert {:ok, []} = ReqClient.get("/containers/json")
      assert {:ok, []} = ReqClient.get("/containers/json")

      # Version negotiated once, then cached.
      assert :counters.get(version_hits, 1) == 1
    end

    test "falls back to v1.45 when negotiation fails", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/version", fn conn ->
        Plug.Conn.resp(conn, 500, "boom")
      end)

      Bypass.expect(bypass, "GET", "/v1.45/containers/json", fn conn ->
        json(conn, 200, [])
      end)

      assert {:ok, []} = ReqClient.get("/containers/json")
    end
  end

  describe "error mapping" do
    setup %{bypass: bypass} do
      stub_version(bypass)
      :ok
    end

    test "404 -> {:not_found, body}", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1.47/containers/missing/json", fn conn ->
        Plug.Conn.resp(conn, 404, "no such container")
      end)

      assert {:error, {:not_found, "no such container"}} =
               ReqClient.get("/containers/missing/json")
    end

    test "409 -> {:conflict, body}", %{bypass: bypass} do
      Bypass.expect(bypass, "DELETE", "/v1.47/containers/busy", fn conn ->
        Plug.Conn.resp(conn, 409, "in use")
      end)

      assert {:error, {:conflict, "in use"}} = ReqClient.delete("/containers/busy")
    end

    test "304 -> {:ok, :not_modified}", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1.47/containers/x/start", fn conn ->
        Plug.Conn.resp(conn, 304, "")
      end)

      assert {:ok, :not_modified} = ReqClient.post("/containers/x/start")
    end

    test "500 -> {:http_error, 500, body}", %{bypass: bypass} do
      Bypass.expect(bypass, "GET", "/v1.47/containers/json", fn conn ->
        Plug.Conn.resp(conn, 500, "server error")
      end)

      assert {:error, {:http_error, 500, "server error"}} = ReqClient.get("/containers/json")
    end

    test "closed connection -> {:connection_error, _}", %{bypass: bypass} do
      Bypass.down(bypass)
      assert {:error, {:connection_error, _}} = ReqClient.get("/containers/json")
    end
  end

  describe "split_image_ref/1 (push name/tag splitting)" do
    test "splits a registry ref with a host port, preserving the colon in the host" do
      # A ":" in the host:port must not be mistaken for a tag separator.
      assert ReqClient.split_image_ref("registry.example.com:5000/homelab/app:1.2") ==
               {"registry.example.com:5000/homelab/app", "1.2"}
    end

    test "defaults the tag to latest when absent" do
      assert ReqClient.split_image_ref("library/nginx") == {"library/nginx", "latest"}
    end

    test "splits a simple name:tag" do
      assert ReqClient.split_image_ref("homelab-built/app:2.0") == {"homelab-built/app", "2.0"}
    end
  end

  describe "push/2 end-to-end URL shape" do
    setup do
      # Seed the version cache so push skips negotiation.
      :persistent_term.put({ReqClient, :api_version}, "v1.47")
      :ok
    end

    test "targets /images/{name}/push?tag={tag} and drains the stream", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1.47/images/library/nginx/push", fn conn ->
        assert conn.query_string == "tag=latest"
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, ~s|{"status":"Pushed"}\n|)
        conn
      end)

      assert :ok = ReqClient.push("library/nginx")
    end
  end

  describe "JSON event streaming (build/2)" do
    setup %{bypass: bypass} do
      stub_version(bypass)
      :ok
    end

    test "reassembles events split across chunk boundaries", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1.47/build", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        # A JSON object split mid-way across two chunks.
        {:ok, conn} = Plug.Conn.chunk(conn, ~s|{"stream":"Step |)
        {:ok, conn} = Plug.Conn.chunk(conn, ~s|1/2"}\n{"stream":"done"}\n|)
        conn
      end)

      test_pid = self()
      on_event = fn event -> send(test_pid, {:event, event}) end

      assert :ok = ReqClient.build("t=app", "tarbytes", on_event)
      assert_receive {:event, %{"stream" => "Step 1/2"}}
      assert_receive {:event, %{"stream" => "done"}}
    end

    test "a daemon error event aborts the stream", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1.47/build", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        {:ok, conn} = Plug.Conn.chunk(conn, ~s|{"error":"build blew up"}\n|)
        conn
      end)

      assert {:error, {:build_failed, "build blew up"}} =
               ReqClient.build("t=app", "tarbytes", fn _ -> :ok end)
    end

    test "decodes a trailing unterminated line at end of stream", %{bypass: bypass} do
      Bypass.expect(bypass, "POST", "/v1.47/build", fn conn ->
        conn = Plug.Conn.send_chunked(conn, 200)
        # No trailing newline on the final line.
        {:ok, conn} = Plug.Conn.chunk(conn, ~s|{"stream":"last line"}|)
        conn
      end)

      test_pid = self()
      assert :ok = ReqClient.build("t=app", "tarbytes", fn e -> send(test_pid, {:event, e}) end)
      assert_receive {:event, %{"stream" => "last line"}}
    end
  end
end
