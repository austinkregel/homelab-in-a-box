defmodule Homelab.Deployments.Migrate.ContainerControl do
  @moduledoc """
  Live container lifecycle ops over the Docker Engine API, used by the
  quiesce/resume migration steps.

  `set_restart_policy/2` uses `POST /containers/{id}/update`, which changes the
  restart policy in place without recreating the container — that's how the
  quiesce step disables `restart: always` so the daemon can't resurrect a stopped
  database into a split-brain double-writer during a copy. All ops are idempotent
  (a 304 from stop/start on an already-in-that-state container is treated as `:ok`).
  """

  @behaviour Homelab.Deployments.Migrate.ContainerOps

  alias Homelab.Docker.Client

  @impl true
  def restart_policy(id) do
    case Client.get("/containers/#{id}/json") do
      {:ok, %{"HostConfig" => %{"RestartPolicy" => %{"Name" => name}}}} ->
        {:ok, name || "no"}

      {:ok, _other} ->
        {:ok, "no"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl true
  def set_restart_policy(id, name) do
    case Client.post("/containers/#{id}/update", %{"RestartPolicy" => %{"Name" => name}}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def stop(id, timeout_seconds) do
    # ?t= gives the process that many seconds to shut down cleanly (SIGTERM) before
    # SIGKILL — important for DBs to flush.
    case Client.post("/containers/#{id}/stop?t=#{timeout_seconds}") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def start(id) do
    case Client.post("/containers/#{id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def env(id) do
    case Client.get("/containers/#{id}/json") do
      {:ok, %{"Config" => %{"Env" => env}}} when is_list(env) -> {:ok, parse_env(env)}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def image_env(image) do
    case Client.get("/images/#{image}/json") do
      {:ok, %{"Config" => %{"Env" => env}}} when is_list(env) -> {:ok, parse_env(env)}
      {:ok, _other} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def port_bindings(id) do
    case Client.get("/containers/#{id}/json") do
      {:ok, %{"HostConfig" => %{"PortBindings" => bindings}}} when is_map(bindings) ->
        {:ok, parse_port_bindings(bindings)}

      {:ok, _other} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ["KEY=VALUE", ...] -> %{"KEY" => "VALUE"}
  defp parse_env(list) do
    Map.new(list, fn pair ->
      case String.split(pair, "=", parts: 2) do
        [k, v] -> {k, v}
        [k] -> {k, ""}
      end
    end)
  end

  # %{"5432/tcp" => [%{"HostPort" => "5432"}]} -> [%{"internal","external","protocol"}]
  defp parse_port_bindings(bindings) do
    Enum.flat_map(bindings, fn {port_proto, host_list} ->
      {port, proto} =
        case String.split(port_proto, "/", parts: 2) do
          [p, pr] -> {p, pr}
          [p] -> {p, "tcp"}
        end

      for %{"HostPort" => host_port} <- host_list || [], host_port not in [nil, ""] do
        # `published: true` is not decoration. SpecBuilder.bind_host_ports/1 binds only the
        # ports carrying it, so without it every imported binding was silently dropped and
        # the adopted service came up unreachable on the very ports it used to serve.
        #
        # A port we read out of the original's HostConfig.PortBindings is, by definition,
        # one the operator published on the host.
        %{
          "internal" => port,
          "external" => host_port,
          "protocol" => proto,
          "published" => true
        }
      end
    end)
  end
end
