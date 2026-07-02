defmodule Homelab.Docker.ReqClient do
  @moduledoc """
  The live Docker Engine API client — `Req` over a Unix socket
  (default `/var/run/docker.sock`).

  The API version is negotiated automatically on first request by querying the
  Docker daemon's version endpoint, so it always matches the running daemon
  rather than a hardcoded constant.

  This is the default implementation behind the `Homelab.Docker.Client` façade
  (see `Homelab.Behaviours.DockerClient`).
  """

  @behaviour Homelab.Behaviours.DockerClient

  @default_socket "/var/run/docker.sock"

  @doc """
  Returns the configured Docker socket path.
  """
  def socket_path do
    Application.get_env(:homelab, :docker_socket, @default_socket)
  end

  @impl true
  def get(path, opts \\ []) do
    request(:get, path, opts)
  end

  @impl true
  def post(path, body \\ nil, opts \\ []) do
    opts = if body, do: Keyword.put(opts, :json, body), else: opts
    request(:post, path, opts)
  end

  @impl true
  def post_stream(path, opts \\ []) do
    version = api_version()
    url = "http://localhost/#{version}#{path}"

    base_opts =
      [method: :post, url: url, retry: false, into: :self, receive_timeout: 600_000]
      |> maybe_add_unix_socket()

    merged = Keyword.merge(base_opts, opts)

    case Req.request(merged) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        drain_stream(resp)

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:error, {:not_found, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp drain_stream(%Req.Response{} = resp) do
    receive_loop(resp)
  end

  defp receive_loop(resp) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            process_chunks(chunks, resp)

          :unknown ->
            receive_loop(resp)
        end
    after
      600_000 ->
        {:error, :pull_timeout}
    end
  end

  defp process_chunks([], resp), do: receive_loop(resp)
  defp process_chunks([:done | _rest], _resp), do: :ok
  defp process_chunks([{:error, reason} | _rest], _resp), do: {:error, reason}
  defp process_chunks([{:data, _} | rest], resp), do: process_chunks(rest, resp)
  defp process_chunks([{:trailers, _} | rest], resp), do: process_chunks(rest, resp)

  @impl true
  def build(query, context, on_event) when is_binary(context) and is_function(on_event, 1) do
    version = api_version()
    url = "http://localhost/#{version}/build?#{query}"

    base_opts =
      [
        method: :post,
        url: url,
        body: context,
        headers: [{"content-type", "application/x-tar"}],
        retry: false,
        into: :self,
        receive_timeout: 600_000
      ]
      |> maybe_add_unix_socket()

    case Req.request(base_opts) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        drain_json_stream(resp, "", on_event, :build_failed)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  def push(image, opts \\ []) do
    version = api_version()
    {name, tag} = split_image_ref(image)
    url = "http://localhost/#{version}/images/#{URI.encode(name)}/push?tag=#{URI.encode(tag)}"

    base_opts =
      [method: :post, url: url, retry: false, into: :self, receive_timeout: 600_000]
      |> maybe_add_unix_socket()

    on_event = Keyword.get(opts, :on_event, fn _ -> :ok end)
    req_opts = Keyword.drop(opts, [:on_event])
    merged = Keyword.merge(base_opts, req_opts)

    case Req.request(merged) do
      {:ok, %Req.Response{status: status} = resp} when status in 200..299 ->
        drain_json_stream(resp, "", on_event, :push_failed)

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  def upload_archive(container, path, tar) when is_binary(tar) do
    query = URI.encode_query(%{"path" => path})

    case request(:put, "/containers/#{container}/archive?#{query}",
           body: tar,
           headers: [{"content-type", "application/x-tar"}]
         ) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  # Splits "registry.example.com/homelab-built/app:1.2" into {name, tag},
  # defaulting the tag to "latest". A ":" only counts as a tag separator when it
  # appears in the final path segment (registry host ports contain ":").
  defp split_image_ref(ref) do
    case String.split(ref, "/") do
      [_ | _] = parts ->
        {prefix, last} = {Enum.drop(parts, -1), List.last(parts)}

        case String.split(last, ":", parts: 2) do
          [repo, tag] -> {Enum.join(prefix ++ [repo], "/"), tag}
          [repo] -> {Enum.join(prefix ++ [repo], "/"), "latest"}
        end
    end
  end

  defp drain_json_stream(resp, buffer, on_event, error_tag) do
    receive do
      message ->
        case Req.parse_message(resp, message) do
          {:ok, chunks} ->
            process_stream_chunks(chunks, resp, buffer, on_event, error_tag)

          :unknown ->
            drain_json_stream(resp, buffer, on_event, error_tag)
        end
    after
      600_000 ->
        {:error, :stream_timeout}
    end
  end

  defp process_stream_chunks([], resp, buffer, on_event, error_tag),
    do: drain_json_stream(resp, buffer, on_event, error_tag)

  defp process_stream_chunks([:done | _rest], _resp, buffer, on_event, error_tag),
    do: emit_json_events(buffer, on_event, error_tag, true)

  defp process_stream_chunks([{:error, reason} | _rest], _resp, _buffer, _on_event, _error_tag),
    do: {:error, reason}

  defp process_stream_chunks([{:data, data} | rest], resp, buffer, on_event, error_tag) do
    case emit_json_events(buffer <> data, on_event, error_tag, false) do
      {:cont, remaining} -> process_stream_chunks(rest, resp, remaining, on_event, error_tag)
      {:error, _} = err -> err
    end
  end

  defp process_stream_chunks([{:trailers, _} | rest], resp, buffer, on_event, error_tag),
    do: process_stream_chunks(rest, resp, buffer, on_event, error_tag)

  # Splits the buffer on newlines, decodes each complete JSON line, and forwards
  # it to `on_event`. A daemon `"error"` event aborts the stream. When `final?`,
  # any trailing (unterminated) line is decoded too. Otherwise the trailing
  # partial line is returned to be completed by the next chunk.
  defp emit_json_events(buffer, on_event, error_tag, final?) do
    {lines, rest} =
      case String.split(buffer, "\n") do
        [] -> {[], ""}
        parts -> {Enum.drop(parts, -1), List.last(parts)}
      end

    lines = if final? and rest != "", do: lines ++ [rest], else: lines

    result =
      Enum.reduce_while(lines, :ok, fn line, _acc ->
        line = String.trim(line)

        cond do
          line == "" ->
            {:cont, :ok}

          true ->
            case Jason.decode(line) do
              {:ok, %{"error" => msg} = event} ->
                on_event.(event)
                {:halt, {:error, {error_tag, msg}}}

              {:ok, event} ->
                on_event.(event)
                {:cont, :ok}

              {:error, _} ->
                {:cont, :ok}
            end
        end
      end)

    case result do
      :ok when final? -> :ok
      :ok -> {:cont, rest}
      {:error, _} = err -> err
    end
  end

  @impl true
  def stream_events(filters \\ %{}, _opts \\ []) do
    version = api_version()
    encoded_filters = Jason.encode!(filters)
    url = "http://localhost/#{version}/events?filters=#{URI.encode(encoded_filters)}"

    base_opts =
      [method: :get, url: url, retry: false, into: :self, receive_timeout: :infinity]
      |> maybe_add_unix_socket()

    case Req.request(base_opts) do
      {:ok, %Req.Response{status: 200} = resp} ->
        {:ok, resp}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  @impl true
  def delete(path, opts \\ []) do
    request(:delete, path, opts)
  end

  defp request(method, path, opts) do
    version = api_version()
    url = "http://localhost/#{version}#{path}"

    base_opts =
      [
        method: method,
        url: url,
        retry: false
      ]
      |> maybe_add_unix_socket()

    merged = Keyword.merge(base_opts, opts)

    case Req.request(merged) do
      {:ok, %Req.Response{status: status, body: body}} when status in 200..299 ->
        {:ok, body}

      {:ok, %Req.Response{status: 304}} ->
        {:ok, :not_modified}

      {:ok, %Req.Response{status: 404, body: body}} ->
        {:error, {:not_found, body}}

      {:ok, %Req.Response{status: 409, body: body}} ->
        {:error, {:conflict, body}}

      {:ok, %Req.Response{status: status, body: body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, {:connection_error, reason}}
    end
  end

  defp api_version do
    case :persistent_term.get({__MODULE__, :api_version}, nil) do
      nil -> fetch_and_cache_api_version()
      version -> version
    end
  end

  defp fetch_and_cache_api_version do
    req_opts =
      [method: :get, url: "http://localhost/version", retry: false]
      |> maybe_add_unix_socket()

    version =
      case Req.request(req_opts) do
        {:ok, %Req.Response{status: 200, body: %{"ApiVersion" => v}}} ->
          "v#{v}"

        _ ->
          "v1.45"
      end

    :persistent_term.put({__MODULE__, :api_version}, version)
    version
  end

  defp maybe_add_unix_socket(opts) do
    case socket_path() do
      nil -> opts
      path -> Keyword.put(opts, :unix_socket, path)
    end
  end
end
