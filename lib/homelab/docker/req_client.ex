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
