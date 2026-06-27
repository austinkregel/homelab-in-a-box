defmodule Homelab.Deployments.DeploymentSchemaTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.Deployment

  describe "changeset/2 required & optional fields" do
    test "valid with only required fields, status defaults to :pending" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id
        })

      assert changeset.valid?

      deployment = Ecto.Changeset.apply_changes(changeset)
      assert deployment.status == :pending
      assert deployment.env_overrides == %{}
    end

    test "is invalid when tenant_id is missing" do
      template = insert(:app_template)

      changeset = Deployment.changeset(%Deployment{}, %{app_template_id: template.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).tenant_id
    end

    test "is invalid when app_template_id is missing" do
      tenant = insert(:tenant)

      changeset = Deployment.changeset(%Deployment{}, %{tenant_id: tenant.id})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).app_template_id
    end

    test "is invalid when both required fields are missing" do
      changeset = Deployment.changeset(%Deployment{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.tenant_id
      assert "can't be blank" in errors.app_template_id
    end

    test "casts all optional fields" do
      tenant = insert(:tenant)
      template = insert(:app_template)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          status: :running,
          external_id: "ext-123",
          domain: "app.example.com",
          env_overrides: %{"FOO" => "bar"},
          computed_spec: %{"image" => "x"},
          last_reconciled_at: now,
          error_message: "boom"
        })

      assert changeset.valid?
      d = Ecto.Changeset.apply_changes(changeset)
      assert d.status == :running
      assert d.external_id == "ext-123"
      assert d.domain == "app.example.com"
      assert d.env_overrides == %{"FOO" => "bar"}
      assert d.computed_spec == %{"image" => "x"}
      assert d.last_reconciled_at == now
      assert d.error_message == "boom"
    end
  end

  describe "changeset/2 status inclusion" do
    test "accepts every valid status" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      for status <- [:pending, :deploying, :running, :failed, :stopped, :removing] do
        changeset =
          Deployment.changeset(%Deployment{}, %{
            tenant_id: tenant.id,
            app_template_id: template.id,
            status: status
          })

        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects an unknown status at cast time (Ecto.Enum)" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      changeset =
        Deployment.changeset(%Deployment{}, %{
          tenant_id: tenant.id,
          app_template_id: template.id,
          status: :bogus
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "changeset/2 constraints (via Repo)" do
    # NOTE: changeset/2 declares `unique_constraint([:tenant_id, :app_template_id])`,
    # but the backing DB index was dropped in migration 20260224004500
    # (`drop_if_exists unique_index(:deployments, [:tenant_id, :app_template_id])`).
    # With no index present the constraint never fires, so a duplicate currently
    # inserts successfully. This test pins that *actual* behavior; if the index is
    # ever restored, this is the test to flip to assert the "has already been taken"
    # error instead.
    test "duplicate [:tenant_id, :app_template_id] currently inserts (no backing index)" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      attrs = %{tenant_id: tenant.id, app_template_id: template.id}

      assert {:ok, _} = %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
      assert {:ok, _} = %Deployment{} |> Deployment.changeset(attrs) |> Repo.insert()
    end

    test "same template under a different tenant is allowed" do
      template = insert(:app_template)
      t1 = insert(:tenant)
      t2 = insert(:tenant)

      assert {:ok, _} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: t1.id, app_template_id: template.id})
               |> Repo.insert()

      assert {:ok, _} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: t2.id, app_template_id: template.id})
               |> Repo.insert()
    end

    test "foreign_key_constraint on tenant_id" do
      template = insert(:app_template)

      assert {:error, changeset} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: 999_999_999, app_template_id: template.id})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).tenant_id
    end

    test "foreign_key_constraint on app_template_id" do
      tenant = insert(:tenant)

      assert {:error, changeset} =
               %Deployment{}
               |> Deployment.changeset(%{tenant_id: tenant.id, app_template_id: 999_999_999})
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).app_template_id
    end
  end

  describe "status_changeset/3" do
    test "sets only the status when no opts are given" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :running)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :running
      refute Ecto.Changeset.changed?(changeset, :error_message)
      refute Ecto.Changeset.changed?(changeset, :external_id)
    end

    test "sets error_message via :error opt" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :failed, error: "kaboom")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :error_message) == "kaboom"
    end

    test "sets external_id via :external_id opt" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :running, external_id: "ctr-42")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :external_id) == "ctr-42"
    end

    test "sets both error and external_id together" do
      deployment = insert(:deployment)

      changeset =
        Deployment.status_changeset(deployment, :failed, error: "bad", external_id: "x1")

      assert Ecto.Changeset.get_change(changeset, :error_message) == "bad"
      assert Ecto.Changeset.get_change(changeset, :external_id) == "x1"
    end

    test "a nil :error opt is treated as not provided (falsy guard)" do
      deployment = insert(:deployment, error_message: "old")

      changeset = Deployment.status_changeset(deployment, :running, error: nil)

      refute Ecto.Changeset.changed?(changeset, :error_message)
    end

    test "a nil :external_id opt is treated as not provided (falsy guard)" do
      deployment = insert(:deployment, external_id: "old")

      changeset = Deployment.status_changeset(deployment, :running, external_id: nil)

      refute Ecto.Changeset.changed?(changeset, :external_id)
    end

    test "rejects an invalid status" do
      deployment = insert(:deployment)

      changeset = Deployment.status_changeset(deployment, :nope)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end

    test "persists the new status through the Repo" do
      deployment = insert(:deployment)

      assert {:ok, updated} =
               deployment
               |> Deployment.status_changeset(:running, external_id: "ctr-9")
               |> Repo.update()

      assert updated.status == :running
      assert updated.external_id == "ctr-9"
    end
  end

  describe "reconciled_changeset/1" do
    test "stamps last_reconciled_at to roughly now" do
      deployment = insert(:deployment)

      before = DateTime.utc_now()
      changeset = Deployment.reconciled_changeset(deployment)
      stamped = Ecto.Changeset.get_change(changeset, :last_reconciled_at)

      assert %DateTime{} = stamped
      assert DateTime.compare(stamped, DateTime.add(before, -2, :second)) in [:gt, :eq]
      assert DateTime.compare(stamped, DateTime.add(DateTime.utc_now(), 2, :second)) in [:lt, :eq]
    end

    test "persists via the Repo" do
      deployment = insert(:deployment)

      assert {:ok, updated} =
               deployment |> Deployment.reconciled_changeset() |> Repo.update()

      assert updated.last_reconciled_at != nil
    end
  end
end
