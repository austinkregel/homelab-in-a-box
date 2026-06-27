defmodule Homelab.Deployments.ReleaseSteps.ProvisionCredentials do
  @moduledoc """
  Generates per-deployment credentials (DB password, user, database name, …) once
  and propagates them to every target deployment in the release, so the dependency
  container (e.g. MySQL) and the app container (e.g. Nextcloud) share identical
  values.

  Input (seeded into `resource_handle` at plan time):

    * `"specs"`   — list of `%{"key" =>, "kind" => "password" | "literal",
      "length" =>, "value" =>}`. The `key` is the literal env var name the
      containers expect (e.g. `"MYSQL_PASSWORD"`).
    * `"targets"` — deployment ids to receive the credentials. The release's own
      deployment (`ctx.deployment`) is the canonical owner whose generated value
      is reused on retries (`get_or_create_secret/3`), keeping the saga idempotent.

  No `compensate/2`: credentials are generate-once and harmless to keep — a retried
  release reuses them. They are removed with the deployment row (FK cascade).
  """

  @behaviour Homelab.Deployments.ReleaseStep.Handler

  require Logger

  alias Homelab.Deployments.Releases

  @impl true
  def run(step, ctx) do
    app_id = ctx.deployment.id
    specs = Map.get(step.resource_handle, "specs", [])
    targets = Map.get(step.resource_handle, "targets", [app_id])

    provisioned =
      Enum.map(specs, fn spec ->
        key = spec["key"]
        # Canonical, generate-once value lives on the app deployment.
        value = Releases.get_or_create_secret(app_id, key, fn -> generate(spec) end)

        # Propagate the identical value to the other targets (the companion).
        for target_id <- targets, target_id != app_id do
          Releases.put_secret(target_id, key, value)
        end

        key
      end)

    Logger.info(
      "[provision_credentials] #{length(provisioned)} secret(s) for deployment #{app_id}"
    )

    {:ok, %{"provisioned" => provisioned}}
  end

  defp generate(%{"kind" => "literal", "value" => value}), do: value
  defp generate(%{"kind" => "password"} = spec), do: random(spec["length"] || 32)
  defp generate(spec), do: spec["value"] || random(32)

  defp random(length) do
    :crypto.strong_rand_bytes(length)
    |> Base.url_encode64(padding: false)
    |> binary_part(0, length)
  end
end
