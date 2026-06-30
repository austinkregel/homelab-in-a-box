defmodule Homelab.Docker.UnavailableClient do
  @moduledoc """
  Test default for the Docker client: emulates a daemon that cannot be reached,
  returning the same `{:error, {:connection_error, _}}` shape `ReqClient` returns
  when the socket is absent.

  This is the global `:docker_client` in test (config/test.exs), so the many code
  paths that incidentally reach the Docker client (metrics, the setup wizard, the
  event listener, …) behave exactly as they did against a real-but-unreachable
  daemon. Tests that actually want to exercise Docker logic opt in *per process*
  with `Process.put(:docker_client, Homelab.Mocks.DockerClient)` — never mutating
  global state — so they cannot race concurrent tests.
  """

  @behaviour Homelab.Behaviours.DockerClient

  @err {:error, {:connection_error, :docker_unavailable}}

  @impl true
  def get(_path, _opts \\ []), do: @err

  @impl true
  def post(_path, _body \\ nil, _opts \\ []), do: @err

  @impl true
  def delete(_path, _opts \\ []), do: @err

  @impl true
  def post_stream(_path, _opts \\ []), do: @err

  @impl true
  def stream_events(_filters \\ %{}, _opts \\ []), do: @err
end
