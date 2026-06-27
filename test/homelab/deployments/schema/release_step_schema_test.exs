defmodule Homelab.Deployments.ReleaseStepSchemaTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.{Release, ReleaseStep}

  defp insert_release(status \\ :planning) do
    deployment = insert(:deployment)

    {:ok, release} =
      %Release{}
      |> Release.changeset(%{
        tenant_id: deployment.tenant_id,
        app_template_id: deployment.app_template_id,
        deployment_id: deployment.id,
        status: status
      })
      |> Repo.insert()

    release
  end

  describe "changeset/2 required & optional fields" do
    test "valid with required fields; status defaults to :pending" do
      release = insert_release()

      changeset =
        ReleaseStep.changeset(%ReleaseStep{}, %{
          release_id: release.id,
          type: :network,
          position: 1
        })

      assert changeset.valid?
      step = Ecto.Changeset.apply_changes(changeset)
      assert step.status == :pending
      assert step.resource_handle == %{}
      assert step.attempts == 0
    end

    test "requires release_id, type, position" do
      changeset = ReleaseStep.changeset(%ReleaseStep{}, %{})

      refute changeset.valid?
      errors = errors_on(changeset)
      assert "can't be blank" in errors.release_id
      assert "can't be blank" in errors.type
      assert "can't be blank" in errors.position
    end

    test "casts optional fields" do
      release = insert_release()

      changeset =
        ReleaseStep.changeset(%ReleaseStep{}, %{
          release_id: release.id,
          type: :app_container,
          position: 5,
          status: :running,
          resource_handle: %{"external_id" => "ctr-1"},
          attempts: 3,
          error_message: "x"
        })

      assert changeset.valid?
      s = Ecto.Changeset.apply_changes(changeset)
      assert s.status == :running
      assert s.resource_handle == %{"external_id" => "ctr-1"}
      assert s.attempts == 3
      assert s.error_message == "x"
    end
  end

  describe "changeset/2 type inclusion" do
    test "accepts every type from types/0" do
      release = insert_release()

      ReleaseStep.types()
      |> Enum.with_index(1)
      |> Enum.each(fn {type, idx} ->
        changeset =
          ReleaseStep.changeset(%ReleaseStep{}, %{
            release_id: release.id,
            type: type,
            position: idx
          })

        assert changeset.valid?, "expected #{type} to be valid"
      end)
    end

    test "rejects an unknown type (Ecto.Enum)" do
      release = insert_release()

      changeset =
        ReleaseStep.changeset(%ReleaseStep{}, %{
          release_id: release.id,
          type: :not_a_type,
          position: 1
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :type)
    end
  end

  describe "changeset/2 status inclusion" do
    test "accepts every status from statuses/0" do
      release = insert_release()

      ReleaseStep.statuses()
      |> Enum.with_index(1)
      |> Enum.each(fn {status, idx} ->
        changeset =
          ReleaseStep.changeset(%ReleaseStep{}, %{
            release_id: release.id,
            type: :network,
            position: idx,
            status: status
          })

        assert changeset.valid?, "expected #{status} to be valid"
      end)
    end

    test "rejects an unknown status (Ecto.Enum)" do
      release = insert_release()

      changeset =
        ReleaseStep.changeset(%ReleaseStep{}, %{
          release_id: release.id,
          type: :network,
          position: 1,
          status: :nope
        })

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end
  end

  describe "changeset/2 constraints (via Repo)" do
    test "foreign_key_constraint on release_id" do
      assert {:error, changeset} =
               %ReleaseStep{}
               |> ReleaseStep.changeset(%{
                 release_id: 999_999_999,
                 type: :network,
                 position: 1
               })
               |> Repo.insert()

      assert "does not exist" in errors_on(changeset).release_id
    end

    test "unique [:release_id, :position]" do
      release = insert_release()

      assert {:ok, _} =
               %ReleaseStep{}
               |> ReleaseStep.changeset(%{release_id: release.id, type: :network, position: 1})
               |> Repo.insert()

      assert {:error, changeset} =
               %ReleaseStep{}
               |> ReleaseStep.changeset(%{
                 release_id: release.id,
                 type: :app_container,
                 position: 1
               })
               |> Repo.insert()

      assert "has already been taken" in errors_on(changeset).release_id
    end

    test "same position under a different release is allowed" do
      r1 = insert_release()
      r2 = insert_release()

      assert {:ok, _} =
               %ReleaseStep{}
               |> ReleaseStep.changeset(%{release_id: r1.id, type: :network, position: 1})
               |> Repo.insert()

      assert {:ok, _} =
               %ReleaseStep{}
               |> ReleaseStep.changeset(%{release_id: r2.id, type: :network, position: 1})
               |> Repo.insert()
    end
  end

  describe "progress_changeset/3" do
    test "sets only status when no opts given" do
      step = %ReleaseStep{status: :pending, resource_handle: %{}}

      changeset = ReleaseStep.progress_changeset(step, :running)

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :status) == :running
      refute Ecto.Changeset.changed?(changeset, :resource_handle)
      refute Ecto.Changeset.changed?(changeset, :error_message)
    end

    test "merges :handle into resource_handle" do
      step = %ReleaseStep{status: :running, resource_handle: %{}}

      changeset =
        ReleaseStep.progress_changeset(step, :completed,
          handle: %{"kind" => "container", "external_id" => "abc"}
        )

      assert Ecto.Changeset.get_change(changeset, :resource_handle) ==
               %{"kind" => "container", "external_id" => "abc"}
    end

    test ":handle with empty map is still applied (fetch semantics)" do
      step = %ReleaseStep{status: :running, resource_handle: %{"old" => "v"}}

      changeset = ReleaseStep.progress_changeset(step, :completed, handle: %{})

      # %{} given explicitly => change recorded clearing the handle.
      assert Ecto.Changeset.get_change(changeset, :resource_handle) == %{}
    end

    test "sets error_message via :error opt" do
      step = %ReleaseStep{status: :running}

      changeset = ReleaseStep.progress_changeset(step, :failed, error: "kaboom")

      assert Ecto.Changeset.get_change(changeset, :error_message) == "kaboom"
    end

    test "a nil :error opt is treated as not provided" do
      step = %ReleaseStep{status: :running, error_message: "old"}

      changeset = ReleaseStep.progress_changeset(step, :completed, error: nil)

      refute Ecto.Changeset.changed?(changeset, :error_message)
    end

    test "handle and error together" do
      step = %ReleaseStep{status: :running, resource_handle: %{}}

      changeset =
        ReleaseStep.progress_changeset(step, :failed,
          handle: %{"x" => 1},
          error: "bad"
        )

      assert Ecto.Changeset.get_change(changeset, :resource_handle) == %{"x" => 1}
      assert Ecto.Changeset.get_change(changeset, :error_message) == "bad"
    end

    test "rejects an invalid status" do
      step = %ReleaseStep{status: :running}

      changeset = ReleaseStep.progress_changeset(step, :nope)

      refute changeset.valid?
      assert Keyword.has_key?(changeset.errors, :status)
    end

    test "persists via Repo" do
      release = insert_release()

      {:ok, step} =
        %ReleaseStep{}
        |> ReleaseStep.changeset(%{release_id: release.id, type: :network, position: 1})
        |> Repo.insert()

      assert {:ok, updated} =
               step
               |> ReleaseStep.progress_changeset(:completed, handle: %{"net" => "homelab"})
               |> Repo.update()

      assert updated.status == :completed
      assert updated.resource_handle == %{"net" => "homelab"}
    end
  end

  describe "helper functions" do
    test "types/0 lists all step types" do
      assert ReleaseStep.types() == [
               :network,
               :provision_credentials,
               :dependency_container,
               :await_health,
               :app_container,
               :publish_ingress,
               :backup_verify,
               :adopt_credentials,
               :quiesce_old,
               :migrate_volume,
               :resume_old,
               :adopt_volume,
               :adopt_container,
               :verify_integrity
             ]
    end

    test "statuses/0 lists all step statuses" do
      assert ReleaseStep.statuses() ==
               [:pending, :running, :completed, :compensating, :compensated, :failed, :skipped]
    end
  end
end
