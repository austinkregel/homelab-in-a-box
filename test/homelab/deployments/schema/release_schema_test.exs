defmodule Homelab.Deployments.ReleaseSchemaTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.Release

  defp release_attrs(overrides \\ %{}) do
    deployment = insert(:deployment)

    Map.merge(
      %{
        tenant_id: deployment.tenant_id,
        app_template_id: deployment.app_template_id,
        deployment_id: deployment.id
      },
      overrides
    )
  end

  describe "changeset/2 required & optional fields" do
    test "valid with only required fields, status defaults to :planning" do
      changeset = Release.changeset(%Release{}, release_attrs())

      assert changeset.valid?
      release = Ecto.Changeset.apply_changes(changeset)
      assert release.status == :planning
      assert release.plan == %{}
    end

    test "requires tenant_id, app_template_id, deployment_id" do
      changeset = Release.changeset(%Release{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.tenant_id
      assert "can't be blank" in errors.app_template_id
      assert "can't be blank" in errors.deployment_id
    end

    test "casts all optional fields" do
      expires = DateTime.utc_now() |> DateTime.truncate(:second)

      changeset =
        Release.changeset(
          %Release{},
          release_attrs(%{
            status: :provisioning,
            lease_owner: "node@a",
            lease_expires_at: expires,
            plan: %{"steps" => 3},
            error_message: "oops"
          })
        )

      assert changeset.valid?
      r = Ecto.Changeset.apply_changes(changeset)
      assert r.status == :provisioning
      assert r.lease_owner == "node@a"
      assert r.lease_expires_at == expires
      assert r.plan == %{"steps" => 3}
      assert r.error_message == "oops"
    end
  end

  describe "changeset/2 status inclusion" do
    test "accepts every status returned by statuses/0" do
      for status <- Release.statuses() do
        changeset = Release.changeset(%Release{}, release_attrs(%{status: status}))
        assert changeset.valid?, "expected #{status} to be valid"
      end
    end

    test "rejects an unknown status (Ecto.Enum)" do
      changeset = Release.changeset(%Release{}, release_attrs(%{status: :bogus}))

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "changeset/2 constraints (via Repo)" do
    test "foreign_key_constraint on deployment_id" do
      tenant = insert(:tenant)
      template = insert(:app_template)

      assert {:error, changeset} =
               %Release{}
               |> Release.changeset(%{
                 tenant_id: tenant.id,
                 app_template_id: template.id,
                 deployment_id: 999_999_999
               })
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).deployment_id
    end

    test "foreign_key_constraint on tenant_id" do
      deployment = insert(:deployment)

      assert {:error, changeset} =
               %Release{}
               |> Release.changeset(%{
                 tenant_id: 999_999_999,
                 app_template_id: deployment.app_template_id,
                 deployment_id: deployment.id
               })
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).tenant_id
    end

    test "foreign_key_constraint on app_template_id" do
      deployment = insert(:deployment)

      assert {:error, changeset} =
               %Release{}
               |> Release.changeset(%{
                 tenant_id: deployment.tenant_id,
                 app_template_id: 999_999_999,
                 deployment_id: deployment.id
               })
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).app_template_id
    end

    test "enforces one active release per deployment (partial unique index)" do
      deployment = insert(:deployment)

      base = %{
        tenant_id: deployment.tenant_id,
        app_template_id: deployment.app_template_id,
        deployment_id: deployment.id
      }

      assert {:ok, _} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :planning))
               |> Repo.insert()

      assert {:error, changeset} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :provisioning))
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).deployment_id
    end

    test "a second release is allowed once the first is in a terminal status" do
      deployment = insert(:deployment)

      base = %{
        tenant_id: deployment.tenant_id,
        app_template_id: deployment.app_template_id,
        deployment_id: deployment.id
      }

      # First release lands in a terminal (non-active) status, so the partial
      # index does not cover it.
      assert {:ok, _} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :superseded))
               |> Repo.insert()

      assert {:ok, _} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :planning))
               |> Repo.insert()
    end

    test "two terminal releases for the same deployment are both allowed" do
      deployment = insert(:deployment)

      base = %{
        tenant_id: deployment.tenant_id,
        app_template_id: deployment.app_template_id,
        deployment_id: deployment.id
      }

      assert {:ok, _} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :rolled_back))
               |> Repo.insert()

      assert {:ok, _} =
               %Release{}
               |> Release.changeset(Map.put(base, :status, :superseded))
               |> Repo.insert()
    end
  end

  describe "status_changeset/3 — error semantics" do
    test "sets error_message via :error opt" do
      release = %Release{status: :provisioning}

      changeset = Release.status_changeset(release, :failed, error: "boom")

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :error_message) == "boom"
    end

    test "a nil :error opt is treated as not provided" do
      release = %Release{status: :provisioning, error_message: "old"}

      changeset = Release.status_changeset(release, :running, error: nil)

      refute Ecto.Changeset.changed?(changeset, :error_message)
    end
  end

  describe "status_changeset/3 — lease semantics (fetch vs falsy)" do
    test "lease keys not provided => no change to lease fields" do
      release = %Release{status: :planning, lease_owner: "node@a", lease_expires_at: nil}

      changeset = Release.status_changeset(release, :provisioning)

      refute Ecto.Changeset.changed?(changeset, :lease_owner)
      refute Ecto.Changeset.changed?(changeset, :lease_expires_at)
    end

    test "explicit nil lease_owner clears the lease (distinct from not-provided)" do
      release = %Release{status: :provisioning, lease_owner: "node@a"}

      changeset = Release.status_changeset(release, :running, lease_owner: nil)

      assert Ecto.Changeset.changed?(changeset, :lease_owner)
      assert Ecto.Changeset.get_change(changeset, :lease_owner) == nil
    end

    test "explicit nil lease_expires_at clears it" do
      expires = DateTime.utc_now() |> DateTime.truncate(:second)
      release = %Release{status: :provisioning, lease_expires_at: expires}

      changeset = Release.status_changeset(release, :running, lease_expires_at: nil)

      assert Ecto.Changeset.changed?(changeset, :lease_expires_at)
      assert Ecto.Changeset.get_change(changeset, :lease_expires_at) == nil
    end

    test "setting a lease owner + expiry" do
      expires = DateTime.utc_now() |> DateTime.add(60, :second) |> DateTime.truncate(:second)
      release = %Release{status: :planning}

      changeset =
        Release.status_changeset(release, :provisioning,
          lease_owner: "node@b",
          lease_expires_at: expires
        )

      assert Ecto.Changeset.get_change(changeset, :lease_owner) == "node@b"
      assert Ecto.Changeset.get_change(changeset, :lease_expires_at) == expires
    end

    test "clears lease while setting status, persisted via Repo" do
      deployment = insert(:deployment)

      {:ok, release} =
        %Release{}
        |> Release.changeset(%{
          tenant_id: deployment.tenant_id,
          app_template_id: deployment.app_template_id,
          deployment_id: deployment.id,
          status: :provisioning,
          lease_owner: "node@a"
        })
        |> Repo.insert()

      assert {:ok, updated} =
               release
               |> Release.status_changeset(:running, lease_owner: nil, lease_expires_at: nil)
               |> Repo.update()

      assert updated.status == :running
      assert updated.lease_owner == nil
      assert updated.lease_expires_at == nil
    end

    test "rejects an invalid status" do
      changeset = Release.status_changeset(%Release{}, :nope)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "helper functions" do
    test "statuses/0 returns the full ordered status list" do
      assert Release.statuses() == [
               :planning,
               :provisioning,
               :running,
               :failed,
               :rolling_back,
               :rolled_back,
               :rollback_failed,
               :superseded
             ]
    end

    test "terminal_statuses/0" do
      assert Release.terminal_statuses() ==
               [:running, :failed, :rolled_back, :rollback_failed, :superseded]
    end

    test "active_statuses/0" do
      assert Release.active_statuses() == [:planning, :provisioning, :rolling_back]
    end

    test "active and terminal statuses are disjoint and together cover all statuses" do
      active = MapSet.new(Release.active_statuses())
      terminal = MapSet.new(Release.terminal_statuses())

      assert MapSet.disjoint?(active, terminal)
      assert MapSet.union(active, terminal) == MapSet.new(Release.statuses())
    end

    test "terminal?/1 true for every terminal status" do
      for status <- Release.terminal_statuses() do
        assert Release.terminal?(%Release{status: status})
      end
    end

    test "terminal?/1 false for every active status" do
      for status <- Release.active_statuses() do
        refute Release.terminal?(%Release{status: status})
      end
    end
  end
end
