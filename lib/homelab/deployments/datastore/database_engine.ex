defmodule Homelab.Deployments.Datastore.DatabaseEngine do
  @moduledoc """
  How declared databases get applied to a running datastore.

  One implementation ships (`ContainerDatabaseEngine`, a one-shot client container);
  tests swap in a stub via `config :homelab, :datastore_database_engine`. The seam
  exists so the release step can be tested without a Docker daemon — the SQL and the
  declaration parsing are pure and tested directly.
  """

  @type params :: %{
          engine: module(),
          image: String.t(),
          host: String.t(),
          port: pos_integer(),
          network: String.t(),
          admin_user: String.t(),
          admin_password: String.t(),
          databases: [String.t()],
          sql: String.t() | nil
        }

  @callback reconcile(params()) :: {:ok, map()} | {:error, term()}
end
