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

  describe "driving_release/1" do
    test "returns the release where the deployment is the app" do
      deployment = insert(:deployment)
      release = plan(deployment)

      found = Releases.driving_release(deployment.id)
      assert found.id == release.id
      assert length(found.steps) == 6
    end

    test "resolves the app's release from a companion referenced in a step" do
      tenant = insert(:tenant)
      app = insert(:deployment, tenant: tenant)
      companion = insert(:deployment, tenant: tenant)

      {:ok, release} =
        Releases.plan_release(app, [
          %{type: :dependency_container, resource_handle: %{"deployment_id" => companion.id}},
          %{type: :await_health, resource_handle: %{"deployment_id" => companion.id}},
          %{type: :app_container}
        ])

      # The companion has no release of its own, but its lifecycle is driven here.
      found = Releases.driving_release(companion.id)
      assert found.id == release.id
    end

    test "returns the newest release when several exist for the app" do
      deployment = insert(:deployment)
      old = plan(deployment)
      # Retire it so the one-active-per-deployment constraint permits a second.
      old |> Ecto.Changeset.change(status: :superseded) |> Repo.update!()
      new = plan(deployment)

      assert Releases.driving_release(deployment.id).id == new.id
    end

    test "nil when the deployment has no release" do
      deployment = insert(:deployment)
      assert Releases.driving_release(deployment.id) == nil
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

  describe "abandon_release/2" do
    # `ensure_no_active_release/1` refuses to plan while a release is active, and a
    # release interrupted mid-compensation stays active forever — so that deployment
    # could never be re-imported and there was no way out short of SQL.
    test "unblocks the deployment: the wedged release goes terminal and a new one can plan" do
      deployment = insert(:deployment)
      wedged = plan(deployment)
      {:ok, wedged} = Releases.transition_release(wedged, :rolling_back, [:planning])

      assert Releases.get_active_release(deployment.id).id == wedged.id

      assert {:ok, abandoned} = Releases.abandon_release(wedged)
      assert abandoned.status == :failed
      assert Release.terminal?(abandoned)
      assert Releases.get_active_release(deployment.id) == nil

      # The whole point: the next attempt can now be planned.
      assert {:ok, _fresh} = Releases.plan_release(deployment, [%{type: :app_container}])
    end

    # It must not become a way to lose data quietly. The recorded note is what the UI's
    # confirmation quotes, so it is pinned rather than left to drift.
    test "records what was and was not touched, and clears the lease" do
      deployment = insert(:deployment)
      release = plan(deployment)
      {:ok, release} = Releases.acquire_lease(release, "node@a")

      assert {:ok, abandoned} = Releases.abandon_release(release, by: "ops@example.com")

      assert abandoned.error_message =~ "Nothing was stopped, removed or deleted"
      assert abandoned.error_message =~ "no container, no volume, no directory, no secret"
      assert abandoned.error_message =~ "ops@example.com"
      assert Releases.abandon_note() =~ "Nothing was stopped, removed or deleted"

      # Cleared, so the reconciler does not resume what an operator just abandoned.
      assert abandoned.lease_owner == nil
      assert abandoned.lease_expires_at == nil
    end

    # Steps are left exactly as they are — abandoning is NOT a rollback, and claiming
    # steps were compensated when nothing ran would be the quiet data loss this guards.
    test "compensates nothing — completed steps keep their status and their handles" do
      deployment = insert(:deployment)
      release = plan(deployment)
      [step | _] = Enum.sort_by(release.steps, & &1.position)

      {:ok, running} = Releases.transition_step(step, :running, [:pending])
      handle = %{"external_id" => "container-abc"}

      {:ok, completed} =
        Releases.transition_step(running, :completed, [:running], handle: handle)

      assert {:ok, _} = Releases.abandon_release(Releases.get_release!(release.id))

      still_there = Repo.get!(Homelab.Deployments.ReleaseStep, completed.id)
      assert still_there.status == :completed
      assert still_there.resource_handle == %{"external_id" => "container-abc"}
    end

    test "a terminal release is a no-op, so two operators cannot fight over it" do
      deployment = insert(:deployment)
      release = plan(deployment)

      assert {:ok, _} = Releases.abandon_release(release)
      assert {:noop, again} = Releases.abandon_release(Releases.get_release!(release.id))
      assert again.status == :failed
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

  describe "list_releases_for_deployment/2" do
    test "returns releases newest-first with steps preloaded" do
      deployment = insert(:deployment)
      release = plan(deployment)

      # Advance to a terminal status so a second release is allowed.
      {:ok, _} = Releases.transition_release(release, :running, [:planning, :provisioning])

      {:ok, second} = Releases.plan_release(deployment, [%{type: :app_container}])

      assert [first_listed, second_listed] = Releases.list_releases_for_deployment(deployment.id)
      assert first_listed.id == second.id
      assert second_listed.id == release.id
      refute match?(%Ecto.Association.NotLoaded{}, first_listed.steps)
    end

    test "respects the limit" do
      deployment = insert(:deployment)
      release = plan(deployment)
      {:ok, _} = Releases.transition_release(release, :running, [:planning, :provisioning])
      {:ok, _} = Releases.plan_release(deployment, [%{type: :app_container}])

      assert length(Releases.list_releases_for_deployment(deployment.id, 1)) == 1
    end
  end

  describe "PubSub broadcasts" do
    test "transition_release broadcasts on the deployment topic" do
      deployment = insert(:deployment)
      release = plan(deployment)
      Phoenix.PubSub.subscribe(Homelab.PubSub, Releases.topic(deployment.id))

      {:ok, _} = Releases.transition_release(release, :provisioning, [:planning])
      assert_receive {:release_updated, deployment_id}
      assert deployment_id == deployment.id
    end

    test "transition_step broadcasts on the deployment topic" do
      deployment = insert(:deployment)
      release = plan(deployment)
      step = Releases.next_pending_step(release)
      Phoenix.PubSub.subscribe(Homelab.PubSub, Releases.topic(deployment.id))

      {:ok, _} = Releases.transition_step(step, :completed, [:pending])
      assert_receive {:release_updated, deployment_id}
      assert deployment_id == deployment.id
    end

    test "a no-op transition does not broadcast" do
      deployment = insert(:deployment)
      release = plan(deployment)
      step = Releases.next_pending_step(release)
      {:ok, _} = Releases.transition_step(step, :completed, [:pending])

      Phoenix.PubSub.subscribe(Homelab.PubSub, Releases.topic(deployment.id))
      assert {:noop, _} = Releases.transition_step(step, :failed, [:pending])
      refute_receive {:release_updated, _}
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
