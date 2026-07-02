defmodule Homelab.Behaviours.DockerClient do
  @moduledoc """
  Behaviour for the low-level Docker Engine API HTTP client.

  `Homelab.Docker.Client` is a thin façade that dispatches to the implementation
  configured at `config :homelab, :docker_client` (defaults to
  `Homelab.Docker.ReqClient`, which talks to the daemon over a Unix socket). In
  tests it is swapped for a Mox mock so the request-building and response-parsing
  logic of every Docker-coupled module can be exercised without a real daemon.
  """

  @type path :: String.t()
  @type opts :: keyword()
  @type body :: term()

  @callback get(path, opts) :: {:ok, term()} | {:error, term()}
  @callback post(path, body, opts) :: {:ok, term()} | {:error, term()}
  @callback delete(path, opts) :: {:ok, term()} | {:error, term()}
  @callback post_stream(path, opts) :: :ok | {:error, term()}
  @callback stream_events(filters :: map(), opts) :: {:ok, term()} | {:error, term()}

  @doc """
  Builds an image from a tar build context, streaming each decoded build event
  (e.g. `%{"stream" => "Step 1/4 ..."}`) to `on_event`. Returns `:ok` on success
  or `{:error, reason}` if the daemon reports a build error or the request fails.
  """
  @callback build(query :: String.t(), context :: binary(), on_event :: (map() -> any())) ::
              :ok | {:error, term()}

  @doc """
  Pushes a local image reference to its registry, streaming each decoded push
  event to `on_event`. `opts` must carry the `X-Registry-Auth` header. Returns
  `:ok` on success or `{:error, reason}` on a push error / failed request.
  """
  @callback push(image :: String.t(), opts) :: :ok | {:error, term()}

  @doc """
  Uploads a raw (uncompressed) tar into a container filesystem at `path`
  (`PUT /containers/{id}/archive`). Used to place config files (e.g. htpasswd)
  into a system container.
  """
  @callback upload_archive(container :: String.t(), path :: String.t(), tar :: binary()) ::
              :ok | {:error, term()}
end
