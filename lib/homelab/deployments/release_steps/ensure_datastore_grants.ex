defmodule Homelab.Deployments.ReleaseSteps.EnsureDatastoreGrants do
  @moduledoc """
  Makes the datastore actually grant the credentials homelab hands out.

  Runs after the datastore container is healthy and before the app starts, so an
  app never boots against a database that will reject it. See
  `Homelab.Deployments.Datastore.Grants` for why declaring a password is not the
  same as applying one.

  Expects `step.resource_handle` with:

    * `"deployment_id"` — the DATASTORE deployment (the companion). Supplies the
      admin credential and the engine.
    * `"app_deployment_id"` — the APP deployment. Supplies the user/password/database
      to grant. Defaults to the release's own deployment.
    * `"keys"` (optional) — explicit env var names, e.g.
      `%{"user" => "DB_USERNAME", "password" => "DB_PASSWORD"}`.

  Grants what the APP sends, not what the datastore's own env says — those are
  different secrets under different key names, and confusing them is what left
  aut.hair with `Access denied` even after its database had been "repaired".

  No `compensate/2`: the step only creates a user/database and resets a password to
  the value homelab already holds. There is nothing to undo that would not be
  destructive, and a rolled-back release leaves a correctly-credentialed database
  behind, which is harmless.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.Datastore.Grants
  alias Homelab.Deployments.{Releases, SpecBuilder}

  @default_port 3306

  @impl true
  def run(step, ctx) do
    with {:ok, datastore} <- load_datastore(step),
         {:ok, app} <- load_app(step, ctx),
         {:ok, engine} <- Grants.engine_for_image(datastore.app_template.image),
         {:ok, creds} <-
           Grants.credentials_from_env(
             effective_env(app),
             effective_env(datastore),
             step.resource_handle["keys"] || %{}
           ) do
      params =
        Map.merge(creds, %{
          engine: engine,
          image: datastore.app_template.image,
          host: SpecBuilder.service_name(datastore.tenant, datastore.app_template),
          port: @default_port,
          network: SpecBuilder.tenant_network(datastore.tenant)
        })

      case grants_engine().reconcile(params) do
        {:ok, result} -> {:ok, Map.put(result, "deployment_id", datastore.id)}
        {:error, reason} -> {:error, {:ensure_datastore_grants_failed, datastore.id, reason}}
      end
    end
  end

  defp load_datastore(step) do
    case step.resource_handle["deployment_id"] do
      nil -> {:error, {:ensure_datastore_grants_failed, :no_deployment_id}}
      id -> fetch(id)
    end
  end

  # The app is the release's own deployment unless the plan names another.
  defp load_app(step, ctx) do
    case step.resource_handle["app_deployment_id"] do
      nil -> {:ok, ctx.deployment}
      id -> fetch(id)
    end
  end

  defp fetch(id) do
    case Deployments.get_deployment(id) do
      {:ok, deployment} ->
        {:ok, deployment}

      {:error, :not_found} ->
        {:error, {:ensure_datastore_grants_failed, {:deployment_not_found, id}}}
    end
  end

  # The same merge DeployContainer performs, so we reconcile against exactly the
  # credentials the containers were handed -- not the template defaults.
  defp effective_env(datastore) do
    base = datastore.app_template.default_env || %{}

    base
    |> Map.merge(datastore.env_overrides || %{})
    |> Map.merge(Releases.decrypted_secrets(datastore.id))
  end

  defp grants_engine do
    Application.get_env(
      :homelab,
      :datastore_grants_engine,
      Homelab.Deployments.Datastore.ContainerGrantsEngine
    )
  end
end
