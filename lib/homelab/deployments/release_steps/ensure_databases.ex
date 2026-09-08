defmodule Homelab.Deployments.ReleaseSteps.EnsureDatabases do
  @moduledoc """
  Makes the databases a datastore DECLARES actually exist, on every release.

  Runs after the datastore container is healthy and before anything that depends on
  it starts, so an app never boots against a database that is not there. See
  `Homelab.Deployments.Datastore.Databases` for the declaration and
  `Homelab.Deployments.Datastore.Engine` for why the SQL lives one module per engine.

  ## Why a step and not an init script

  `/docker-entrypoint-initdb.d` and the images' own `POSTGRES_DB` /
  `MARIADB_DATABASE` env are FIRST-INIT ONLY: they run against an empty data
  directory and are skipped forever after. So the sixth database an operator needs,
  three months in, cannot be added by the mechanism that created the first five. What
  actually happens then is a scramble for an SQL client — and a deploy that needs a
  human with `psql` is a deploy that stalls.

  Reconciling on every release removes that cliff entirely. A name added to the
  declaration exists after the next deploy; a name already there costs one catalog
  lookup. Auto-migrating frameworks (Laravel, Ecto) need exactly this and no more —
  an empty database that exists — and then take care of their own schema.

  Expects `step.resource_handle` with an optional `"deployment_id"` naming the
  datastore; absent, the release's own deployment is the datastore. That covers both
  shapes: a datastore deployed on its own, and one deployed as an app's companion.

  No `compensate/2`: the step only creates databases, never drops them (a typo in an
  env var must not be able to destroy data), and a rolled-back release leaving an
  empty database behind is harmless.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Datastore.{Databases, Engine}
  alias Homelab.Deployments.{Releases, SpecBuilder}

  @impl true
  def skip?(step, ctx) do
    with {:ok, datastore} <- load_datastore(step, ctx),
         {:ok, _engine} <- Engine.for_image(image(datastore)),
         {:ok, [_ | _]} <- Databases.declared(effective_env(datastore)) do
      :run
    else
      {:ok, []} ->
        {:skip, "this datastore declares no #{Databases.declaration_key()}"}

      {:error, {:unsupported_engine, _image}} ->
        {:skip, "this deployment is not a datastore homelab can create databases on"}

      {:error, reason} ->
        {:skip, "database declaration unusable: #{inspect(reason)}"}
    end
  end

  @impl true
  def run(step, ctx) do
    with {:ok, datastore} <- load_datastore(step, ctx),
         {:ok, engine} <- Engine.for_image(image(datastore)),
         env = effective_env(datastore),
         {:ok, databases} <- Databases.declared(env),
         {:ok, admin_password} <- admin_password(engine, env, datastore) do
      params = %{
        engine: engine,
        image: image(datastore),
        host: SpecBuilder.service_name(datastore.tenant, datastore.app_template),
        port: engine.default_port(),
        network: SpecBuilder.tenant_network(datastore.tenant),
        admin_user: engine.admin_user(env),
        admin_password: admin_password,
        databases: databases,
        sql: Databases.build_sql(engine, databases)
      }

      case database_engine().reconcile(params) do
        {:ok, result} -> {:ok, Map.put(result, "deployment_id", datastore.id)}
        {:error, reason} -> {:error, {:ensure_databases_failed, datastore.id, reason}}
      end
    end
  end

  defp load_datastore(step, ctx) do
    case step.resource_handle["deployment_id"] do
      nil -> own(ctx)
      id -> fetch(id)
    end
  end

  defp own(%{deployment: %{} = deployment}), do: {:ok, deployment}
  defp own(_ctx), do: {:error, {:ensure_databases_failed, :no_deployment}}

  defp fetch(id) do
    case Deployments.get_deployment(id) do
      {:ok, deployment} -> {:ok, deployment}
      {:error, :not_found} -> {:error, {:ensure_databases_failed, {:deployment_not_found, id}}}
    end
  end

  defp image(%{app_template: %{image: image}}), do: image
  defp image(_deployment), do: nil

  # Without the admin credential nothing can be created, and failing here names the
  # missing variable rather than surfacing an authentication error from the client.
  defp admin_password(engine, env, datastore) do
    case engine.admin_password(env) do
      nil -> {:error, {:ensure_databases_failed, datastore.id, :no_admin_password}}
      password -> {:ok, password}
    end
  end

  # The same merge DeployContainer performs, so we reconcile against exactly the
  # credentials the container was handed -- not the template defaults.
  defp effective_env(datastore) do
    base = datastore.app_template.default_env || %{}

    base
    |> Map.merge(datastore.env_overrides || %{})
    |> Map.merge(Releases.decrypted_secrets(datastore.id))
  end

  defp database_engine do
    Application.get_env(
      :homelab,
      :datastore_database_engine,
      Homelab.Deployments.Datastore.ContainerDatabaseEngine
    )
  end
end
