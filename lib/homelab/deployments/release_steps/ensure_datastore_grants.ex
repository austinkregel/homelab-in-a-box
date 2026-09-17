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
  example.org with `Access denied` even after its database had been "repaired".

  No `compensate/2`: the step only creates a user/database and resets a password to
  the value homelab already holds. There is nothing to undo that would not be
  destructive, and a rolled-back release leaves a correctly-credentialed database
  behind, which is harmless.
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments
  alias Homelab.Deployments.{Access, Releases, SpecBuilder}
  alias Homelab.Deployments.Datastore.Grants
  alias Homelab.Deployments.ReleaseSteps.Conditions

  @default_port 3306

  # Only engines `Grants` can drive; the facts are built for the companion this step
  # targets.
  @impl true
  def skip?(_step, ctx) do
    Conditions.all(ctx.facts, [
      {:datastore?, "this companion is not a datastore homelab can grant on"}
    ])
  end

  @impl true
  def run(step, ctx) do
    with {:ok, datastore} <- load_datastore(step),
         {:ok, app} <- load_app(step, ctx),
         {:ok, engine} <- Grants.engine_for_image(datastore_image(datastore)),
         {:ok, creds} <-
           Grants.credentials_from_env(
             effective_env(app),
             effective_env(datastore),
             step.resource_handle["keys"] || %{}
           ),
         {:ok, host} <- reachable_host(datastore) do
      params =
        Map.merge(creds, %{
          engine: engine,
          image: datastore_image(datastore),
          host: host,
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

  # Where the throwaway client dials. A datastore in a netns donor's namespace has no
  # name of its own — its port answers on the donor's address — so its own service name
  # resolves to nothing and the failure reads as the datastore being down. Same
  # resolution `EnsureDatabases` makes, for the same reason.
  defp reachable_host(datastore) do
    case SpecBuilder.reachable_service_name(datastore) do
      nil -> {:error, {:grants_failed, datastore.id, :donor_not_found}}
      host -> {:ok, host}
    end
  end

  # The image the datastore is ACTUALLY running. `image_override` is what a version bump
  # writes, and `DeployContainer` deploys `Access.effective_image/1`, so reading the
  # template decided "is this a datastore" from a container that may not exist -- and
  # handed `ContainerGrantsEngine` the wrong client image to run.
  defp datastore_image(%{app_template: %{image: _}} = deployment),
    do: Access.effective_image(deployment)

  defp datastore_image(%{image_override: image}) when is_binary(image), do: image
  defp datastore_image(_deployment), do: nil

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
