defmodule Homelab.Deployments.Datastore.ContainerGrantsEngine do
  @moduledoc """
  Applies datastore grants from a throwaway client container on the tenant network.

  The Docker client has no `exec` support, and adding it would be a much larger
  surface than this needs. A one-shot container reaches the datastore over the
  tenant network by service name — the same pattern `ContainerCopyEngine` already
  uses — and is removed immediately whether it succeeds or fails.

  The container runs the datastore's OWN image, which is guaranteed to ship a
  matching client binary (`mariadb`/`mysql`) and to speak its wire protocol.

  Credentials never appear in argv: the admin password rides `MYSQL_PWD` and the
  statements ride `GRANTS_SQL`, both read from the environment by the shell. argv
  is world-readable inside the container via /proc.

  Select with `config :homelab, :datastore_grants_engine`.
  """

  @behaviour Homelab.Deployments.Datastore.Grants

  require Logger

  alias Homelab.Deployments.Datastore.Grants
  alias Homelab.Docker.Client

  @wait_timeout 120_000

  @impl true
  def reconcile(params) do
    with {:ok, sql} <- Grants.build_sql(params),
         {:ok, id} <- create(params, sql) do
      result = run_and_collect(id, params)
      _ = remove(id)
      result
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
      "[datastore_grants] reconciled #{params.app_user}@#{params.database} on #{params.host}"
    )

    {:ok, %{"user" => params.app_user, "database" => params.database, "reconciled" => true}}
  end

  # The admin credential is the one thing this cannot repair: if root is rejected,
  # the volume predates homelab's provisioning and needs a human.
  defp interpret(status, log, _params) do
    if String.contains?(log, "Access denied for user") do
      {:error, {:admin_access_denied, String.slice(log, -500, 500)}}
    else
      {:error, {:grants_failed, status, String.slice(log, -2000, 2000)}}
    end
  end

  defp create(params, sql) do
    body = %{
      "Image" => params.image,
      "Cmd" => ["/bin/sh", "-c", script()],
      "Env" => [
        "MYSQL_PWD=#{params.admin_password}",
        "GRANTS_SQL=#{sql}",
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

  # The datastore may still be accepting connections a moment after it reports
  # healthy, so retry the connect briefly rather than failing the release on a race.
  @doc false
  def script do
    """
    set -eu
    client=$(command -v mariadb || command -v mysql)
    i=0
    while [ $i -lt 10 ]; do
      if printf '%s' "$GRANTS_SQL" | "$client" -h "$DB_HOST" -P "$DB_PORT" -u "$DB_ADMIN"; then
        exit 0
      fi
      i=$((i+1))
      sleep 2
    done
    exit 1
    """
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
