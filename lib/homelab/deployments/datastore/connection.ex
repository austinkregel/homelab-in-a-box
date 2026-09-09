defmodule Homelab.Deployments.Datastore.Connection do
  @moduledoc """
  The connection strings a TCP-routed datastore is actually reachable at.

  A TCP route publishes a database at a hostname, and every detail that makes a client
  reach it is non-obvious in the same direction — each one, got wrong, produces an error
  that points somewhere other than the cause:

    * **The port is 443, not 5432.** The route rides the `websecure` entrypoint, so the
      hostname is a name Traefik terminates TLS for. Nothing is listening on 5432.

    * **`sslmode` must be `require` or stricter.** SNI is the only thing a TCP router can
      match on, and it exists only inside a TLS handshake. A client that sends none
      matches no TCP router, falls through to the HTTP routers sharing the entrypoint, and
      reports `expected authentication request from server, but received H` — the `H`
      being the first byte of `HTTP/1.1`. `verify-full` is what this renders, because the
      certificate is a real public one and there is no reason to accept less.

    * **The engine has to be Postgres.** Postgres negotiates TLS inside its own protocol
      rather than opening with a handshake, and Traefik implements exactly that
      negotiation. MySQL/MariaDB's equivalent is not implemented, so a route to one works
      only for a client doing implicit TLS. `unsupported_engine` says so rather than
      rendering a string that will not connect.

  No password is rendered. The value lives in the deployment's secrets and the Environment
  tab is what reveals it, with the masking that page already applies; duplicating it into
  a string on another tab would put a credential on screen with no control to hide it.
  """

  alias Homelab.Deployments.Access
  alias Homelab.Deployments.Datastore.Databases
  alias Homelab.Deployments.Datastore.Engine

  @type connection :: %{
          host: String.t(),
          port: non_neg_integer(),
          database: String.t(),
          user: String.t(),
          url: String.t(),
          engine: :postgres
        }

  # Every TCP route rides `websecure`, so this is the port a client dials — not the
  # container port the route forwards to.
  @client_port 443

  @doc """
  Connection strings for every (TCP route × declared database) pair on `deployment`.

  Returns `[]` when the deployment has no TCP routes, declares no databases, or runs an
  engine whose TLS negotiation Traefik cannot drive. Empty is the honest answer for all
  three: there is nothing to connect to, nothing to connect to it with, or nothing that
  would work.
  """
  @spec for_deployment(map()) :: [connection()]
  def for_deployment(deployment) do
    env = effective_env(deployment)

    with {:ok, module} <- postgres_engine(deployment),
         {:ok, databases} when databases != [] <- Databases.declared(env) do
      user = module.admin_user(env)

      for route <- routes(deployment), database <- databases do
        build(route["host"], database, user)
      end
    else
      _ -> []
    end
  end

  # Postgres only, by name rather than by "whatever engine resolved". `Engine.for_image/1`
  # happily returns the MySQL module, and that is exactly the case this must not render a
  # string for.
  defp postgres_engine(deployment) do
    case Engine.for_image(Access.effective_image(deployment)) do
      {:ok, Engine.Postgres} = ok -> ok
      _ -> :error
    end
  end

  defp routes(deployment) do
    deployment
    |> Map.get(:tcp_routes)
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1["host"]) and &1["host"] != ""))
  end

  defp effective_env(deployment) do
    template_env = (deployment.app_template && deployment.app_template.default_env) || %{}

    Map.merge(template_env, deployment.env_overrides || %{})
  end

  defp build(host, database, user) do
    %{
      host: host,
      port: @client_port,
      database: database,
      user: user,
      engine: :postgres,
      url:
        "postgresql://#{user}@#{host}:#{@client_port}/#{URI.encode(database)}?sslmode=verify-full"
    }
  end
end
