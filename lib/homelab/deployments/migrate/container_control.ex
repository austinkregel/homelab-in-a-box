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
end
