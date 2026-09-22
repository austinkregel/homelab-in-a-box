defmodule Homelab.Backups.Targets.S3 do
  @moduledoc """
  Archives in S3-compatible object storage — AWS, Backblaze B2, MinIO, Wasabi, R2.

  Signed with Req's built-in `:aws_sigv4`, so this needs no AWS SDK and no new
  dependency. One frame is one multipart part, which is why the writer frames at all:
  nothing here re-chunks, and an interrupted upload resumes at the last completed part
  rather than at byte zero.

  Every part carries `x-amz-checksum-sha256` and the completion repeats the per-part
  checksums, so the store verifies what arrived independently of anything this app
  computed. That is the difference between "we wrote 500 GB" and "500 GB arrived
  intact".

  A local target protects a volume; this protects against losing the machine.
  """

  @behaviour Homelab.Backups.Target

  alias Homelab.Backups.Archive

  require Logger

  # S3 allows 10,000 parts. At the default 64 MiB frame that is 640 GB, and the writer
  # scales the frame up beyond that rather than silently exceeding it here.
  @max_parts 10_000
  @receive_timeout 120_000

  @impl true
  def kind, do: "s3"

  @impl true
  def display_name, do: "S3-compatible storage"

  @impl true
  def open(config, key, _opts \\ []) do
    case request(config, :post, object_url(config, key, "uploads="), "") do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        case extract(body, "UploadId") do
          nil -> {:error, {:no_upload_id, body}}
          id -> {:ok, %{config: config, key: key, upload_id: id, part: 1, parts: [], bytes: 0}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:initiate_failed, status, body}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  @impl true
  def write(%{part: part}, _frame) when part > @max_parts do
    {:error, {:too_many_parts, @max_parts}}
  end

  def write(handle, frame) do
    %{config: config, key: key, upload_id: upload_id, part: part} = handle
    data = IO.iodata_to_binary(frame)
    checksum = data |> then(&:crypto.hash(:sha256, &1)) |> Base.encode64()

    query = "partNumber=#{part}&uploadId=#{upload_id}"
    headers = [{"x-amz-checksum-sha256", checksum}]

    case request(config, :put, object_url(config, key, query), data, headers) do
      {:ok, %{status: status} = response} when status in 200..299 ->
        {:ok,
         %{
           handle
           | part: part + 1,
             bytes: handle.bytes + byte_size(data),
             parts: [{part, etag(response), checksum} | handle.parts]
         }}

      {:ok, %{status: status, body: body}} ->
        {:error, {:part_failed, part, status, body}}

      {:error, reason} ->
        {:error, {:part_failed, part, :unreachable, reason}}
    end
  end

  @impl true
  def close(%{parts: []} = handle) do
    # S3 rejects a multipart upload with no parts, and an empty archive is legitimate
    # (an empty volume still has a tar header). Abort the upload and PUT the object
    # whole instead.
    %{config: config, key: key} = handle
    abort(handle)

    case request(config, :put, object_url(config, key), "") do
      {:ok, %{status: status}} when status in 200..299 -> {:ok, %{bytes: 0, frames: 0}}
      {:ok, %{status: status, body: body}} -> {:error, {:put_failed, status, body}}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  def close(handle) do
    %{config: config, key: key, upload_id: upload_id, parts: parts} = handle
    ordered = Enum.sort_by(parts, &elem(&1, 0))

    case request(
           config,
           :post,
           object_url(config, key, "uploadId=#{upload_id}"),
           completion_xml(ordered)
         ) do
      {:ok, %{status: status, body: body}} when status in 200..299 ->
        # S3 reports a per-part failure inside a 200 response, so the body has to be
        # read rather than trusting the status line.
        if String.contains?(to_string(body), "<Error>") do
          {:error, {:complete_failed, status, body}}
        else
          {:ok, %{bytes: handle.bytes, frames: length(ordered), etag: extract(body, "ETag")}}
        end

      {:ok, %{status: status, body: body}} ->
        {:error, {:complete_failed, status, body}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  @impl true
  def abort(%{config: config, key: key, upload_id: upload_id}) do
    request(config, :delete, object_url(config, key, "uploadId=#{upload_id}"), "")
    :ok
  rescue
    _ -> :ok
  end

  def abort(_), do: :ok

  @impl true
  def read_stream(config, key, opts \\ []) do
    # Every frame but the last is exactly `frame_size` of payload plus the framing
    # overhead, so the object can be walked with range requests instead of held open
    # as one long-lived streaming response. That also makes a resumed read trivial:
    # each range stands alone.
    case Keyword.get(opts, :frame_size) do
      nil ->
        {:error, :frame_size_required}

      frame_size ->
        span = frame_size + Archive.frame_overhead()

        {:ok,
         Stream.unfold(0, fn
           :done ->
             nil

           offset ->
             case get_range(config, key, offset, span) do
               {:ok, <<>>} -> nil
               {:ok, data} when byte_size(data) < span -> {data, :done}
               {:ok, data} -> {data, offset + byte_size(data)}
               {:error, reason} -> raise "reading #{key} at #{offset}: #{inspect(reason)}"
             end
         end)}
    end
  end

  @impl true
  def stat(config, key) do
    case request(config, :head, object_url(config, key), "") do
      {:ok, %{status: 200, headers: headers}} ->
        {:ok,
         %{
           bytes: headers |> header(["content-length"]) |> to_integer(),
           checksum: header(headers, ["x-amz-checksum-sha256"])
         }}

      {:ok, %{status: 404}} ->
        {:error, {:not_found, key}}

      {:ok, %{status: status}} ->
        {:error, {:stat_failed, status}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  @impl true
  def list(config, prefix) do
    full = Path.join(prefix_of(config), prefix)
    url = "#{base_url(config)}?list-type=2&prefix=#{URI.encode_www_form(full)}"

    case request(config, :get, url, "") do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_listing(to_string(body), prefix_of(config))}

      {:ok, %{status: status, body: body}} ->
        {:error, {:list_failed, status, body}}

      {:error, reason} ->
        {:error, {:unreachable, reason}}
    end
  end

  @impl true
  def delete(config, key) do
    case request(config, :delete, object_url(config, key), "") do
      {:ok, %{status: status}} when status in 200..299 or status == 404 -> :ok
      {:ok, %{status: status, body: body}} -> {:error, {:delete_failed, status, body}}
      {:error, reason} -> {:error, {:unreachable, reason}}
    end
  end

  # -- requests --

  defp get_range(config, key, offset, span) do
    headers = [{"range", "bytes=#{offset}-#{offset + span - 1}"}]

    case request(config, :get, object_url(config, key), "", headers) do
      {:ok, %{status: status, body: body}} when status in [200, 206] -> {:ok, body}
      {:ok, %{status: 416}} -> {:ok, <<>>}
      {:ok, %{status: 404}} -> {:error, {:not_found, key}}
      {:ok, %{status: status, body: body}} -> {:error, {:range_failed, status, body}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp request(config, method, url, body, headers \\ []) do
    headers = headers ++ storage_class_header(config, method)

    options =
      [
        method: method,
        url: url,
        body: body,
        headers: headers,
        decode_body: false,
        receive_timeout: @receive_timeout,
        # Transient by default: a 500 or a dropped connection part-way through a
        # multi-hour upload should cost one part, not the whole transfer.
        retry: get(config, :retry, :transient),
        aws_sigv4: [
          access_key_id: fetch!(config, :access_key_id),
          secret_access_key: fetch!(config, :secret_access_key),
          region: get(config, :region, "us-east-1"),
          service: :s3
        ]
      ]

    Req.request(Req.new(options))
  end

  # The storage class rides on the object's creation, which for a multipart upload is
  # the initiate call, not the parts and not the completion.
  defp storage_class_header(config, :post) do
    case get(config, :storage_class, nil) do
      nil -> []
      "" -> []
      class -> [{"x-amz-storage-class", class}]
    end
  end

  defp storage_class_header(_config, _method), do: []

  # -- urls --

  defp base_url(config) do
    endpoint = config |> fetch!(:endpoint) |> String.trim_trailing("/")
    "#{endpoint}/#{fetch!(config, :bucket)}"
  end

  defp object_url(config, key, query \\ nil) do
    path =
      prefix_of(config)
      |> Path.join(key)
      |> String.split("/")
      |> Enum.reject(&(&1 == ""))
      |> Enum.map_join("/", fn segment -> URI.encode(segment, &URI.char_unreserved?/1) end)

    url = "#{base_url(config)}/#{path}"
    if query, do: url <> "?" <> query, else: url
  end

  defp prefix_of(config), do: get(config, :prefix, "") || ""

  # -- xml --

  # Minimal extraction rather than an XML dependency: these are three fixed shapes in
  # responses this module itself asked for, not arbitrary documents.
  defp extract(body, tag) do
    case Regex.run(~r/<#{tag}>([^<]*)<\/#{tag}>/, to_string(body)) do
      [_, value] -> value
      _ -> nil
    end
  end

  defp completion_xml(parts) do
    body =
      Enum.map_join(parts, fn {number, etag, checksum} ->
        "<Part><PartNumber>#{number}</PartNumber><ETag>#{etag}</ETag>" <>
          "<ChecksumSHA256>#{checksum}</ChecksumSHA256></Part>"
      end)

    ~s(<?xml version="1.0" encoding="UTF-8"?>) <>
      ~s(<CompleteMultipartUpload xmlns="http://s3.amazonaws.com/doc/2006-03-01/">) <>
      body <> "</CompleteMultipartUpload>"
  end

  defp parse_listing(body, prefix) do
    ~r/<Contents>.*?<Key>([^<]*)<\/Key>.*?<Size>(\d+)<\/Size>.*?<\/Contents>/s
    |> Regex.scan(body)
    |> Enum.map(fn [_, key, size] ->
      %{key: strip_prefix(key, prefix), bytes: String.to_integer(size)}
    end)
  end

  defp strip_prefix(key, ""), do: key

  defp strip_prefix(key, prefix) do
    trimmed = String.trim_trailing(prefix, "/") <> "/"

    case String.starts_with?(key, trimmed) do
      true -> String.replace_prefix(key, trimmed, "")
      false -> key
    end
  end

  # -- headers --

  defp etag(%{headers: headers}), do: header(headers, ["etag"]) || ""

  defp header(headers, names) when is_map(headers) do
    Enum.find_value(names, fn name ->
      case Map.get(headers, name) do
        [value | _] -> value
        value when is_binary(value) -> value
        _ -> nil
      end
    end)
  end

  defp header(headers, names) when is_list(headers) do
    Enum.find_value(headers, fn {name, value} ->
      if String.downcase(name) in names, do: value
    end)
  end

  defp to_integer(nil), do: 0
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> 0
    end
  end

  # -- config --

  defp fetch!(config, key) do
    case get(config, key, nil) do
      value when is_binary(value) and value != "" ->
        value

      _ ->
        raise ArgumentError, """
        The S3 backup target is missing #{key}.

        An archive written to a half-configured target is one nobody can find again.
        Set endpoint, bucket, access key and secret under Settings -> Backups.
        """
    end
  end

  defp get(config, key, default) do
    case Map.get(config, key) do
      nil -> Map.get(config, Atom.to_string(key), default)
      value -> value
    end
  end
end
