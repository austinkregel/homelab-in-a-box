defmodule Homelab.Deployments.SecretsOnDeployTest do
  @moduledoc """
  Generated and adopted credentials must reach the container on EVERY deploy path.

  They used to be merged by the release-step handlers — `DeployContainer` and
  `AdoptContainer` each did it themselves — which meant the two imperative paths
  (`start_deployment/1` and `do_deploy/1`) silently did not. `recreate_deployment/1` is
  `start_deployment/1`, and that is what every config save on the deployment page runs.

  So saving one env var recreated the container with every generated DB password and
  every adopted credential missing from its env, while pressing "Redeploy" (which plans
  a release) put them back — the behaviour depended on which button you pressed. A
  datastore with an already-initialised data dir then rejected the app's login, and the
  error surfaced from inside the app rather than from the platform.

  The merge now lives in `SpecBuilder.build_env/5`, the one seam all four
  `SpecBuilder.build/1` callers share.
  """
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{Releases, SpecBuilder}

  setup do
    deployment = insert(:deployment, status: :running, external_id: "c1")

    {:ok, _} = Releases.put_secret(deployment.id, "MYSQL_PASSWORD", "s3cret-generated")

    %{deployment: Deployments.get_deployment!(deployment.id)}
  end

  test "the spec every deploy path builds carries the deployment's secrets", ctx do
    assert {:ok, spec} = SpecBuilder.build(ctx.deployment)

    assert spec.env["MYSQL_PASSWORD"] == "s3cret-generated"
  end

  test "an operator env override cannot shadow a generated credential", ctx do
    # Secrets merge LAST. The alternative is an operator who typed a placeholder into
    # the env editor silently replacing the password the datastore was actually
    # provisioned with.
    {:ok, deployment} =
      Deployments.update_deployment(ctx.deployment, %{
        env_overrides: %{"MYSQL_PASSWORD" => "whatever-i-typed"}
      })

    assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(deployment.id))
    assert spec.env["MYSQL_PASSWORD"] == "s3cret-generated"
  end

  test "a secret that cannot be decrypted is OMITTED, never passed as a blank value", ctx do
    # `Crypto.decrypt/1` returns nil when the key changed (the homelab-iab-secrets volume
    # was recreated, or SECRET_KEY_BASE differs). That nil used to be merged straight into
    # the container env, so the app started against an empty password — either rejected
    # with a confusing auth error, or treating its store as uninitialised. A MISSING
    # variable fails loudly and correctly.
    corrupt =
      Homelab.Repo.get_by!(Homelab.Deployments.DeploymentSecret,
        deployment_id: ctx.deployment.id,
        key: "MYSQL_PASSWORD"
      )

    Homelab.Repo.update_all(
      from(s in Homelab.Deployments.DeploymentSecret, where: s.id == ^corrupt.id),
      set: [value: "not-decryptable-ciphertext"]
    )

    assert {:ok, spec} = SpecBuilder.build(Deployments.get_deployment!(ctx.deployment.id))

    refute Map.has_key?(spec.env, "MYSQL_PASSWORD")
  end

  test "a preloaded empty secret set is honoured without a query", ctx do
    # The DB-free spec tests rely on this: an explicit [] means "this deployment has
    # none", where not-loaded means look them up.
    spec_input = %{ctx.deployment | secrets: []}

    assert {:ok, spec} = SpecBuilder.build(spec_input)
    refute Map.has_key?(spec.env, "MYSQL_PASSWORD")
  end
end
