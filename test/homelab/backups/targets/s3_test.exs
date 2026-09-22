defmodule Homelab.Backups.Targets.S3Test do
  use ExUnit.Case, async: true

  alias Homelab.Backups.Archive
  alias Homelab.Backups.Targets.S3

  @master_key Base.decode16!("FFEEDDCCBBAA99887766554433221100FFEEDDCCBBAA99887766554433221100")

  setup do
    bypass = Bypass.open()

    config = %{
      endpoint: "http://localhost:#{bypass.port}",
      bucket: "backups",
      region: "us-east-1",
      access_key_id: "AKIAEXAMPLE",
      secret_access_key: "secret",
      prefix: "hiab"
    }

    base = Path.join(System.tmp_dir!(), "hiab-s3-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)

    %{bypass: bypass, config: config, base: base}
  end

  # A stand-in for the object store: keeps parts in an Agent so a test can assert on
  # what actually arrived, and serves them back for range reads.
  defp start_store do
    {:ok, store} = Agent.start_link(fn -> %{uploads: %{}, objects: %{}, requests: []} end)
    store
  end

  defp stub_s3(bypass, store) do
    Bypass.stub(bypass, "POST", "/backups/hiab/:a/:b", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      key = Enum.join(conn.path_info, "/")
      record(store, conn)

      cond do
        conn.query_string =~ "uploads" ->
          id = "upload-#{System.unique_integer([:positive])}"
          Agent.update(store, &put_in(&1.uploads[id], []))

          xml(
            conn,
            "<InitiateMultipartUploadResult><UploadId>#{id}</UploadId>" <>
              "</InitiateMultipartUploadResult>"
          )

        true ->
          id = upload_id(conn)
          parts = Agent.get(store, & &1.uploads[id]) || []

          assembled =
            parts
            |> Enum.sort_by(&elem(&1, 0))
            |> Enum.map_join("", &elem(&1, 1))

          # The completion must name every part that was uploaded, in order.
          numbers =
            Regex.scan(~r/<PartNumber>(\d+)<\/PartNumber>/, body) |> Enum.map(&List.last/1)

          assert numbers ==
                   parts |> Enum.map(&elem(&1, 0)) |> Enum.sort() |> Enum.map(&to_string/1)

          Agent.update(store, &put_in(&1.objects[key], assembled))

          xml(
            conn,
            "<CompleteMultipartUploadResult><ETag>\"done\"</ETag>" <>
              "</CompleteMultipartUploadResult>"
          )
      end
    end)

    Bypass.stub(bypass, "PUT", "/backups/hiab/:a/:b", fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn, length: 50_000_000)
      record(store, conn)
      id = upload_id(conn)

      case id do
        nil ->
          Agent.update(store, &put_in(&1.objects[Enum.join(conn.path_info, "/")], body))
          Plug.Conn.resp(conn, 200, "")

        id ->
          number = conn |> part_number() |> String.to_integer()
          Agent.update(store, &update_in(&1.uploads[id], fn p -> [{number, body} | p || []] end))

          conn
          |> Plug.Conn.put_resp_header("etag", "\"part-#{number}\"")
          |> Plug.Conn.resp(200, "")
      end
    end)

    Bypass.stub(bypass, "GET", "/backups/hiab/:a/:b", fn conn ->
      key = Enum.join(conn.path_info, "/")
      object = Agent.get(store, & &1.objects[key])
      serve_range(conn, object)
    end)

    Bypass.stub(bypass, "HEAD", "/backups/hiab/:a/:b", fn conn ->
      case Agent.get(store, & &1.objects[Enum.join(conn.path_info, "/")]) do
        nil ->
          Plug.Conn.resp(conn, 404, "")

        object ->
          # Handing the object as the body lets the server compute content-length the
          # way S3 does; it strips the body itself because this is a HEAD.
          Plug.Conn.resp(conn, 200, object)
      end
    end)

    Bypass.stub(bypass, "DELETE", "/backups/hiab/:a/:b", fn conn ->
      record(store, conn)
      Plug.Conn.resp(conn, 204, "")
    end)
  end

  defp serve_range(conn, nil), do: Plug.Conn.resp(conn, 404, "")

  defp serve_range(conn, object) do
    case range_of(conn) do
      nil ->
        Plug.Conn.resp(conn, 200, object)

      {from, _to} when from >= byte_size(object) ->
        Plug.Conn.resp(conn, 416, "")

      {from, to} ->
        len = min(to, byte_size(object) - 1) - from + 1
        Plug.Conn.resp(conn, 206, binary_part(object, from, len))
    end
  end

  defp range_of(conn) do
    case Plug.Conn.get_req_header(conn, "range") do
      ["bytes=" <> spec] ->
        [from, to] = String.split(spec, "-")
        {String.to_integer(from), String.to_integer(to)}

      _ ->
        nil
    end
  end

  defp record(store, conn) do
    entry = %{
      method: conn.method,
      query: conn.query_string,
      headers: Map.new(conn.req_headers)
    }

    Agent.update(store, &update_in(&1.requests, fn r -> r ++ [entry] end))
  end

  defp requests(store), do: Agent.get(store, & &1.requests)

  defp upload_id(conn) do
    URI.decode_query(conn.query_string)["uploadId"]
  end

  defp part_number(conn), do: URI.decode_query(conn.query_string)["partNumber"]

  defp xml(conn, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/xml")
    |> Plug.Conn.resp(200, body)
  end

  describe "signing" do
    test "every request is signed with sigv4", %{bypass: bypass, config: config} do
      store = start_store()
      stub_s3(bypass, store)

      {:ok, handle} = S3.open(config, "vol/a")
      {:ok, handle} = S3.write(handle, "some frame bytes")
      {:ok, _} = S3.close(handle)

      for request <- requests(store) do
        assert request.headers["authorization"] =~ "AWS4-HMAC-SHA256"
        assert request.headers["authorization"] =~ "AKIAEXAMPLE"
        assert Map.has_key?(request.headers, "x-amz-date")
      end
    end
  end

  describe "multipart upload" do
    test "one frame becomes one part, each with its own checksum", %{
      bypass: bypass,
      config: config
    } do
      store = start_store()
      stub_s3(bypass, store)

      frames = ["frame one", "frame two", "frame three"]

      {:ok, handle} = S3.open(config, "vol/parts")

      handle =
        Enum.reduce(frames, handle, fn frame, acc ->
          {:ok, acc} = S3.write(acc, frame)
          acc
        end)

      assert {:ok, meta} = S3.close(handle)
      assert meta.frames == 3
      assert meta.bytes == frames |> Enum.map(&byte_size/1) |> Enum.sum()

      puts = Enum.filter(requests(store), &(&1.method == "PUT"))
      assert length(puts) == 3

      for {request, frame} <- Enum.zip(puts, frames) do
        assert request.headers["x-amz-checksum-sha256"] ==
                 Base.encode64(:crypto.hash(:sha256, frame))
      end
    end

    test "the storage class is set on initiate, not on the parts", %{
      bypass: bypass,
      config: config
    } do
      store = start_store()
      stub_s3(bypass, store)
      config = Map.put(config, :storage_class, "GLACIER_IR")

      {:ok, handle} = S3.open(config, "vol/cold")
      {:ok, handle} = S3.write(handle, "bytes")
      {:ok, _} = S3.close(handle)

      [initiate | _] = Enum.filter(requests(store), &(&1.method == "POST"))
      assert initiate.headers["x-amz-storage-class"] == "GLACIER_IR"

      for put <- Enum.filter(requests(store), &(&1.method == "PUT")) do
        refute Map.has_key?(put.headers, "x-amz-storage-class")
      end
    end

    test "an aborted upload issues a delete", %{bypass: bypass, config: config} do
      store = start_store()
      stub_s3(bypass, store)

      {:ok, handle} = S3.open(config, "vol/abandoned")
      {:ok, handle} = S3.write(handle, "partial")
      assert :ok = S3.abort(handle)

      assert Enum.any?(requests(store), &(&1.method == "DELETE"))
    end

    test "a failing part is reported rather than silently dropped", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "POST", "/backups/hiab/:a/:b", fn conn ->
        xml(
          conn,
          "<InitiateMultipartUploadResult><UploadId>u1</UploadId>" <>
            "</InitiateMultipartUploadResult>"
        )
      end)

      Bypass.stub(bypass, "PUT", "/backups/hiab/:a/:b", fn conn ->
        Plug.Conn.resp(conn, 500, "<Error><Code>InternalError</Code></Error>")
      end)

      # Retries are right in production and only slow this down: the 500 is permanent.
      config = Map.put(config, :retry, false)

      {:ok, handle} = S3.open(config, "vol/badpart")
      assert {:error, {:part_failed, 1, 500, _}} = S3.write(handle, "bytes")
    end

    # S3 reports a per-part failure inside a 200 response, so the completion body has
    # to be read rather than trusting the status line.
    test "an error inside a 200 completion is treated as a failure", %{
      bypass: bypass,
      config: config
    } do
      Bypass.stub(bypass, "POST", "/backups/hiab/:a/:b", fn conn ->
        {:ok, _body, conn} = Plug.Conn.read_body(conn)

        if conn.query_string =~ "uploads" do
          xml(
            conn,
            "<InitiateMultipartUploadResult><UploadId>u1</UploadId>" <>
              "</InitiateMultipartUploadResult>"
          )
        else
          xml(conn, "<Error><Code>InternalError</Code></Error>")
        end
      end)

      Bypass.stub(bypass, "PUT", "/backups/hiab/:a/:b", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("etag", "\"e\"")
        |> Plug.Conn.resp(200, "")
      end)

      {:ok, handle} = S3.open(config, "vol/liar")
      {:ok, handle} = S3.write(handle, "bytes")
      assert {:error, {:complete_failed, 200, _}} = S3.close(handle)
    end
  end

  describe "round trip through the archive" do
    test "a tree survives being written to and read back from S3", %{
      bypass: bypass,
      config: config,
      base: base
    } do
      store = start_store()
      stub_s3(bypass, store)

      source = Path.join(base, "source")
      dest = Path.join(base, "restored")
      File.mkdir_p!(Path.join(source, "nested"))
      File.write!(Path.join(source, "a.txt"), "hello s3")
      File.write!(Path.join(source, "nested/b.bin"), :crypto.strong_rand_bytes(70_000))

      opts = [master_key: @master_key, frame_size: 16_384, compression: :none]

      assert {:ok, manifest} = Archive.create(source, S3, config, "vol/rt", opts)
      assert manifest.frames > 3

      assert :ok = Archive.extract(manifest, S3, config, dest, master_key: @master_key)

      assert File.read!(Path.join(dest, "a.txt")) == "hello s3"

      assert File.read!(Path.join(source, "nested/b.bin")) ==
               File.read!(Path.join(dest, "nested/b.bin"))
    end

    test "corruption in the stored object is caught on the way back", %{
      bypass: bypass,
      config: config,
      base: base
    } do
      store = start_store()
      stub_s3(bypass, store)

      source = Path.join(base, "source")
      dest = Path.join(base, "restored")
      File.mkdir_p!(source)
      File.write!(Path.join(source, "a.bin"), :crypto.strong_rand_bytes(60_000))

      opts = [master_key: @master_key, frame_size: 16_384, compression: :none]
      {:ok, manifest} = Archive.create(source, S3, config, "vol/rot", opts)

      Agent.update(store, fn state ->
        update_in(state.objects, fn objects ->
          Map.new(objects, fn {key, object} ->
            <<head::binary-100, byte, rest::binary>> = object
            {key, <<head::binary, Bitwise.bxor(byte, 0xFF), rest::binary>>}
          end)
        end)
      end)

      assert {:error, _} = Archive.extract(manifest, S3, config, dest, master_key: @master_key)
      refute File.exists?(dest)
    end
  end

  describe "stat and delete" do
    test "reports the stored size", %{bypass: bypass, config: config} do
      store = start_store()
      stub_s3(bypass, store)

      {:ok, handle} = S3.open(config, "vol/sized")
      {:ok, handle} = S3.write(handle, String.duplicate("x", 1234))
      {:ok, _} = S3.close(handle)

      assert {:ok, %{bytes: 1234}} = S3.stat(config, "vol/sized")
    end

    test "a missing object is not found rather than an error", %{
      bypass: bypass,
      config: config
    } do
      store = start_store()
      stub_s3(bypass, store)

      assert {:error, {:not_found, "vol/ghost"}} = S3.stat(config, "vol/ghost")
    end

    test "delete succeeds", %{bypass: bypass, config: config} do
      store = start_store()
      stub_s3(bypass, store)

      assert :ok = S3.delete(config, "vol/gone")
    end
  end

  describe "configuration" do
    test "a half-configured target refuses rather than writing somewhere unfindable" do
      assert_raise ArgumentError, ~r/missing bucket/, fn ->
        S3.open(%{endpoint: "http://localhost", access_key_id: "a", secret_access_key: "b"}, "k")
      end
    end

    test "reading needs the frame size the manifest carries", %{config: config} do
      assert {:error, :frame_size_required} = S3.read_stream(config, "vol/x", [])
    end
  end
end
