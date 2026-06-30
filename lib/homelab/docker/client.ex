defmodule Homelab.Docker.Client do
  @moduledoc """
  Façade for the Docker Engine API client.

  Dispatches to the implementation configured at `config :homelab, :docker_client`
  (defaults to `Homelab.Docker.ReqClient`, which talks to the daemon over a Unix
  socket). In tests this is swapped for `Homelab.Mocks.DockerClient` so the
  request-building and response-parsing logic of every Docker-coupled module can
  be exercised without a real daemon.

  Callers use this module unchanged; default arguments are normalized here so the
  underlying implementation always receives a full-arity call.
  """

  alias Homelab.Docker.ReqClient

  # Resolution order: a process-scoped override (set by tests via
  # `Process.put(:docker_client, mock)` so they never mutate global state and
  # can't race concurrent tests), then the configured default, then ReqClient.
  defp impl do
    Process.get(:docker_client) || Application.get_env(:homelab, :docker_client, ReqClient)
  end

  @doc "Returns the configured Docker socket path (always from the live client)."
  defdelegate socket_path, to: ReqClient

  @doc "Makes a GET request to the Docker Engine API."
  def get(path, opts \\ []), do: impl().get(path, opts)

  @doc "Makes a POST request to the Docker Engine API."
  def post(path, body \\ nil, opts \\ []), do: impl().post(path, body, opts)

  @doc "Makes a DELETE request to the Docker Engine API."
  def delete(path, opts \\ []), do: impl().delete(path, opts)

  @doc """
  Makes a POST request that consumes a streaming response (e.g. image pull).
  Blocks until the stream completes and returns `:ok` or `{:error, reason}`.
  """
  def post_stream(path, opts \\ []), do: impl().post_stream(path, opts)

  @doc """
  Opens a long-lived streaming GET connection to `/events`. See
  `Homelab.Docker.ReqClient.stream_events/2`.
  """
  def stream_events(filters \\ %{}, opts \\ []), do: impl().stream_events(filters, opts)
end
