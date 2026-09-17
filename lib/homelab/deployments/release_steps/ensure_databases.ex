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
  alias Homelab.Deployments.{Access, Releases, SpecBuilder}
  alias Homelab.Deployments.Datastore.{Databases, Engine}

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
         {:ok, admin_password} <- admin_password(engine, env, datastore),
         {:ok, host} <- reachable_host(datastore) do
      params = %{
        engine: engine,
        image: image(datastore),
        host: host,
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

  # The image the datastore is ACTUALLY running, not the one its template names.
  #
  # `image_override` is what a version bump and every hand-edited image write to, and
  # `DeployContainer` deploys `Access.effective_image/1` — so reading the template here
  # made this step reason about a container that may not exist. Two ways that bites, and
  # the first is silent:
  #
  #   * `Engine.for_image/1` decides whether this deployment is a datastore at all. A
  #     Postgres running by override on top of a template that names something else
  #     resolves to `{:error, {:unsupported_engine, _}}`, and `skip?/2` then skips the
  #     step with "not a datastore homelab can create databases on" — on every release,
  #     for as long as the override stands. Nothing fails; the databases simply never
  #     get created.
  #   * `ContainerDatabaseEngine` runs THIS image as the throwaway client. The template's
  #     image is the wrong client version at best, and the wrong engine's binary at worst.
  # Delegated rather than re-derived, so the two can never disagree. The template-loaded
  # clause comes first because `Access.effective_image/1` reads it whenever there is no
  # override; the second covers an unloaded association, which used to fall through to
  # `nil` here and must not start raising instead.
  defp image(%{app_template: %{image: _}} = deployment), do: Access.effective_image(deployment)
  defp image(%{image_override: image}) when is_binary(image), do: image
  defp image(_deployment), do: nil

  # Where the throwaway client actually dials. A datastore in a netns donor's namespace
  # has no name of its own, so its own service name resolves to nothing and the failure
  # reads as "the database is down" rather than "we asked for the wrong name".
  defp reachable_host(datastore) do
    case SpecBuilder.reachable_service_name(datastore) do
      nil -> {:error, {:ensure_databases_failed, datastore.id, :donor_not_found}}
      host -> {:ok, host}
    end
  end

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
