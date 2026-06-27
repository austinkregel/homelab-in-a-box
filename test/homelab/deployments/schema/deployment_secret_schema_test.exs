defmodule Homelab.Deployments.DeploymentSecretSchemaTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.DeploymentSecret

  describe "changeset/2 required fields" do
    test "valid with all required fields" do
      deployment = insert(:deployment)

      changeset =
        DeploymentSecret.changeset(%DeploymentSecret{}, %{
          deployment_id: deployment.id,
          key: "db_password",
          value: "ciphertext"
        })

      assert changeset.valid?
    end

    test "requires deployment_id, key and value" do
      changeset = DeploymentSecret.changeset(%DeploymentSecret{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.deployment_id
      assert "can't be blank" in errors.key
      assert "can't be blank" in errors.value
    end

    test "missing value alone is invalid" do
      deployment = insert(:deployment)

      changeset =
        DeploymentSecret.changeset(%DeploymentSecret{}, %{
          deployment_id: deployment.id,
          key: "k"
        })

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).value
    end

    test "does not cast fields outside the required set" do
      deployment = insert(:deployment)

      changeset =
        DeploymentSecret.changeset(%DeploymentSecret{}, %{
          deployment_id: deployment.id,
          key: "k",
          value: "v",
          inserted_at: ~U[2000-01-01 00:00:00Z]
        })

      assert changeset.valid?
      refute Ecto.Changeset.changed?(changeset, :inserted_at)
    end
  end

  describe "changeset/2 constraints (via Repo)" do
    test "foreign_key_constraint on deployment_id" do
      assert {:error, changeset} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{
                 deployment_id: 999_999_999,
                 key: "k",
                 value: "v"
               })
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).deployment_id
    end

    test "unique [:deployment_id, :key]" do
      deployment = insert(:deployment)

      attrs = %{deployment_id: deployment.id, key: "db_password", value: "v1"}

      assert {:ok, _} =
               %DeploymentSecret{} |> DeploymentSecret.changeset(attrs) |> Repo.insert()

      assert {:error, changeset} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{attrs | value: "v2"})
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).deployment_id
    end

    test "the same key for a different deployment is allowed" do
      d1 = insert(:deployment)
      d2 = insert(:deployment)

      assert {:ok, _} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{
                 deployment_id: d1.id,
                 key: "db_password",
                 value: "v"
               })
               |> Repo.insert()

      assert {:ok, _} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{
                 deployment_id: d2.id,
                 key: "db_password",
                 value: "v"
               })
               |> Repo.insert()
    end

    test "different keys for the same deployment are allowed" do
      deployment = insert(:deployment)

      assert {:ok, _} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{
                 deployment_id: deployment.id,
                 key: "db_user",
                 value: "v"
               })
               |> Repo.insert()

      assert {:ok, _} =
               %DeploymentSecret{}
               |> DeploymentSecret.changeset(%{
                 deployment_id: deployment.id,
                 key: "db_password",
                 value: "v"
               })
               |> Repo.insert()
    end
  end
end
