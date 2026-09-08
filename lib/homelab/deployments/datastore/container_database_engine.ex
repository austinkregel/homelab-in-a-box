defmodule Homelab.Deployments.Datastore.ContainerDatabaseEngine do
  @moduledoc """
  Creates declared databases from a throwaway client container on the tenant network.

  The Docker client has no `exec` support, and adding it would be a much larger
  surface than this needs. A one-shot container reaches the datastore over the tenant
  network by service name — the same pattern `ContainerGrantsEngine` and
  `ContainerCopyEngine` already use — and is removed immediately, success or failure.

  The container runs the datastore's OWN image, which is guaranteed to ship a matching
  client binary and to speak its wire protocol. That is the whole reason an operator
  does not need `psql` on their laptop: the client is already in the image homelab
  just pulled.

  Credentials never appear in argv — the admin password rides the engine's own
  password variable (`PGPASSWORD`, `MYSQL_PWD`) and the statements ride `DB_SQL`, both
  read from the environment by the shell. argv is world-readable inside the container
  via `/proc`.

  Select with `config :homelab, :datastore_database_engine`.
  """

  @behaviour Homelab.Deployments.Datastore.DatabaseEngine

  require Logger

  alias Homelab.Docker.Client

  @wait_timeout 120_000

  @impl true
  def reconcile(%{sql: nil}), do: {:ok, %{"databases" => [], "reconciled" => false}}

  def reconcile(params) do
    case create(params) do
      {:ok, id} ->
        result = run_and_collect(id, params)
        _ = remove(id)
        result

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp run_and_collect(id, params) do
    with :ok <- start(id),
         {:ok, status} <- wait(id),
         {:ok, log} <- logs(id) do
      interpret(status, log, params)
    end
  end

  defp interpret(0, _log, params) do
    Logger.info(
      "[datastore_databases] ensured #{Enum.join(params.databases, ", ")} on #{params.host}"
    )

    {:ok, %{"databases" => params.databases, "reconciled" => true}}
  end

  # The admin credential is the one thing this cannot repair: if it is rejected, the
  # volume predates homelab's provisioning and needs a human.
  defp interpret(status, log, _params) do
    if String.contains?(log, "assword authentication failed") or
         String.contains?(log, "Access denied for user") do
      {:error, {:admin_access_denied, tail(log)}}
    else
      {:error, {:ensure_databases_failed, status, tail(log)}}
    end
  end

  defp tail(log) when byte_size(log) <= 2000, do: log
  defp tail(log), do: String.slice(log, -2000, 2000)

  defp create(params, _opts \\ []) do
    body = %{
      "Image" => params.image,
      "Cmd" => ["/bin/sh", "-c", params.engine.script()],
      "Env" => [
        "#{params.engine.password_env()}=#{params.admin_password}",
        "DB_SQL=#{params.sql}",
        "DB_HOST=#{params.host}",
        "DB_PORT=#{params.port}",
        "DB_ADMIN=#{params.admin_user}"
      ],
      "HostConfig" => %{"AutoRemove" => false, "NetworkMode" => params.network}
    }

    case Client.post("/containers/create", body) do
      {:ok, %{"Id" => id}} -> {:ok, id}
      {:error, reason} -> {:error, {:create_failed, reason}}
    end
  end

  defp start(id) do
    case Client.post("/containers/#{id}/start") do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  defp wait(id) do
    case Client.post("/containers/#{id}/wait", nil, receive_timeout: @wait_timeout) do
      {:ok, %{"StatusCode" => code}} -> {:ok, code}
      {:error, reason} -> {:error, {:wait_failed, reason}}
    end
  end

  defp logs(id) do
    case Client.get("/containers/#{id}/logs?stdout=true&stderr=true") do
      {:ok, body} when is_binary(body) -> {:ok, body}
      {:ok, _} -> {:ok, ""}
      {:error, reason} -> {:error, {:logs_failed, reason}}
    end
  end

  defp remove(id), do: Client.delete("/containers/#{id}?force=true")
end
