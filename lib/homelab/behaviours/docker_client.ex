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
end
