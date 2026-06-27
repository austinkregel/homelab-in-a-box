defmodule Homelab.Deployments.ReleasesTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Repo
  alias Homelab.Deployments.{Release, Releases}

  defp plan(deployment) do
    {:ok, release} =
      Releases.plan_release(deployment, [
        %{type: :network},
        %{type: :provision_credentials},
        %{type: :dependency_container},
        %{type: :await_health},
        %{type: :app_container},
        %{type: :publish_ingress}
      ])

    release
  end

  describe "plan_release/3" do
    test "creates a release with ordered steps" do
      deployment = insert(:deployment)
      release = plan(deployment)

      assert release.status == :planning
      assert release.deployment_id == deployment.id

      positions = Enum.map(release.steps, & &1.position)
      assert positions == [1, 2, 3, 4, 5, 6]
      assert Enum.map(release.steps, & &1.type) |> hd() == :network
      assert Enum.all?(release.steps, &(&1.status == :pending))
    end

    test "enforces one active release per deployment" do
      deployment = insert(:deployment)
      plan(deployment)

      assert {:error, %Ecto.Changeset{} = changeset} =
               Releases.plan_release(deployment, [%{type: :app_container}])

      assert "has already been taken" in errors_on(changeset).deployment_id
    end
  end

  describe "next_pending_step/1 and completed_steps_desc/1" do
    test "returns the lowest pending, and completed in reverse order" do
      deployment = insert(:deployment)
      release = plan(deployment)

      first = Releases.next_pending_step(release)
      assert first.position == 1

      # Complete steps 1 and 2.
      [s1, s2 | _] = Enum.sort_by(release.steps, & &1.position)
      {:ok, _} = Releases.transition_step(s1, :completed, [:pending])
      {:ok, _} = Releases.transition_step(s2, :completed, [:pending])

      release = Releases.get_release!(release.id)
      assert Releases.next_pending_step(release).position == 3
      assert Enum.map(Releases.completed_steps_desc(release), & &1.position) == [2, 1]
    end
  end

  describe "transition_step/4 (guarded)" do
    test "applies when the guard matches and records a handle" do
      deployment = insert(:deployment)
      release = plan(deployment)
      step = Releases.next_pending_step(release)

      assert {:ok, step} =
               Releases.transition_step(step, :completed, [:pending],
                 handle: %{"kind" => "container", "external_id" => "abc"}
               )

      assert step.status == :completed
      assert step.resource_handle == %{"kind" => "container", "external_id" => "abc"}
    end

    test "no-ops when the guard does not match" do
      deployment = insert(:deployment)
      release = plan(deployment)
      step = Releases.next_pending_step(release)

      {:ok, _} = Releases.transition_step(step, :completed, [:pending])
      assert {:noop, _} = Releases.transition_step(step, :failed, [:pending])
    end
  end

  describe "transition_release/4 and lease" do
    test "clears the lease on a terminal transition" do
      deployment = insert(:deployment)
      release = plan(deployment)

      {:ok, leased} = Releases.acquire_lease(release, "node@a")
      assert leased.lease_owner == "node@a"

      {:ok, done} =
        Releases.transition_release(leased, :running, [:planning, :provisioning],
          lease_owner: nil,
          lease_expires_at: nil
        )

      assert done.status == :running
      assert done.lease_owner == nil
    end
  end

  describe "acquire_lease/3" do
    test "a second owner cannot take a live lease, but can take an expired one" do
      deployment = insert(:deployment)
      release = plan(deployment)

      {:ok, _} = Releases.acquire_lease(release, "node@a")
      assert :taken = Releases.acquire_lease(release, "node@b")

      # Force the lease to expire.
      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      Repo.update_all(Release, set: [lease_expires_at: past])

      assert {:ok, taken} = Releases.acquire_lease(Releases.get_release!(release.id), "node@b")
      assert taken.lease_owner == "node@b"
    end
  end

  describe "list_resumable_releases/1" do
    test "finds active releases with an expired lease" do
      deployment = insert(:deployment)
      release = plan(deployment)
      {:ok, _} = Releases.acquire_lease(release, "node@a")

      assert Releases.list_resumable_releases() == []

      past = DateTime.utc_now() |> DateTime.add(-3600, :second) |> DateTime.truncate(:second)
      Repo.update_all(Release, set: [lease_expires_at: past])

      assert [resumable] = Releases.list_resumable_releases()
      assert resumable.id == release.id
    end
  end

  describe "get_or_create_secret/3 (generate-once)" do
    test "generates on first call and reuses thereafter" do
      deployment = insert(:deployment)
      ref = :counters.new(1, [])

      gen = fn ->
        :counters.add(ref, 1, 1)
        "password-#{:counters.get(ref, 1)}"
      end

      first = Releases.get_or_create_secret(deployment.id, "db_password", gen)
      second = Releases.get_or_create_secret(deployment.id, "db_password", gen)

      assert first == second
      assert :counters.get(ref, 1) == 1
      assert Releases.decrypted_secrets(deployment.id) == %{"db_password" => first}
    end
  end
end
