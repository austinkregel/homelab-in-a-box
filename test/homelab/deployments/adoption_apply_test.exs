defmodule Homelab.Deployments.AdoptionApplyTest do
  use Homelab.DataCase, async: false
  use Oban.Testing, repo: Homelab.ObanRepo

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{AdoptionPlanner, Releases}
  alias Homelab.Deployments.ReleaseRunner

  defp plan_for(name \\ "homelab-pg") do
    review = %{
      name: name,
      image: "postgres:16",
      user: "999:999",
      restart_policy: "always",
      container_id: "old-#{name}",
      preserve: [
        %{
          type: "bind",
          source: "/data",
          target: "/var/lib/postgresql/data",
          mountpoint: "/data",
          tier: :preserve
        }
      ],
      rebuildable: [],
      out_of_scope: []
    }

    AdoptionPlanner.build_plan([review])
  end

  test "applies a plan: upserts template, creates pending deployment, enqueues release" do
    tenant = insert(:tenant)
    plan = plan_for()

    assert {:ok, [result]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

    assert result.service == "homelab-pg"
    assert result.deployment.status == :pending
    assert result.deployment.external_id == nil

    template = Homelab.Repo.get(Homelab.Catalog.AppTemplate, result.deployment.app_template_id)
    assert template.source == "adopted"
    assert template.slug == "adopted-homelab-pg"

    # Release planned with the full ordered step list.
    release = Releases.get_release(result.release.id)

    assert Enum.map(release.steps, & &1.type) == [
             :backup_verify,
             :quiesce_old,
             :migrate_volume,
             :resume_old,
             :adopt_credentials,
             :adopt_volume,
             :adopt_container,
             :verify_integrity
           ]

    assert_enqueued(worker: ReleaseRunner, args: %{"release_id" => release.id})
  end

  test "re-run reuses the template + deployment (idempotent) once the release is terminal" do
    tenant = insert(:tenant)
    plan = plan_for()

    assert {:ok, [first]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

    # An in-flight release blocks re-apply.
    assert {:error, {"homelab-pg", :release_in_flight}} =
             Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

    # Drive the release to a terminal state, then re-apply succeeds and reuses rows.
    {:ok, _} = Releases.transition_release(first.release, :running, [:planning, :provisioning])

    assert {:ok, [second]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)
    assert second.deployment.id == first.deployment.id

    templates = Homelab.Repo.all(Homelab.Catalog.AppTemplate)
    assert length(Enum.filter(templates, &(&1.slug == "adopted-homelab-pg"))) == 1
  end

  describe "one container, one deployment — across spaces" do
    # The import space selector was inert until recently, so early imports all landed in
    # whichever space happened to be first. Retrying into the space the operator actually
    # wanted is exactly what produced two deployments claiming one physical container:
    # two rows whose cutover, reconciliation and teardown all target the same container id.
    test "adopting the same container into a second space is refused" do
      first_space = insert(:tenant, name: "Home")
      second_space = insert(:tenant, name: "Media")
      plan = plan_for()

      assert {:ok, [first]} = Deployments.apply_adoption_plan(plan, tenant_id: first_space.id)

      assert {:error, {"homelab-pg", {:adopted_elsewhere, detail}}} =
               Deployments.apply_adoption_plan(plan, tenant_id: second_space.id)

      # Actionable: an operator told only "no" cannot go and deal with the other one.
      assert detail.deployment_id == first.deployment.id
      assert detail.space == "Home"
      assert detail.tenant_id == first_space.id
      assert detail.service == "homelab-pg"

      # And nothing was created in the second space.
      assert Homelab.Repo.all(
               Ecto.Query.from(d in Homelab.Deployments.Deployment,
                 where: d.tenant_id == ^second_space.id
               )
             ) == []
    end

    # The legitimate retry. Same space is already idempotent and must stay that way —
    # this is the path an operator takes after a failed import.
    test "re-adopting into the SAME space still works" do
      space = insert(:tenant)
      plan = plan_for()

      assert {:ok, [first]} = Deployments.apply_adoption_plan(plan, tenant_id: space.id)
      {:ok, _} = Releases.transition_release(first.release, :failed, [:planning, :provisioning])

      assert {:ok, [second]} = Deployments.apply_adoption_plan(plan, tenant_id: space.id)
      assert second.deployment.id == first.deployment.id
    end

    # The guard keys on the adopted TEMPLATE, so it must not spill onto catalog templates,
    # which legitimately have one deployment per space.
    test "an ordinary catalog template is untouched — it may deploy into many spaces" do
      template = insert(:app_template, source: "seeded")
      a = insert(:tenant)
      b = insert(:tenant)

      assert {:ok, _} =
               Deployments.create_deployment(%{
                 tenant_id: a.id,
                 app_template_id: template.id,
                 status: :pending
               })

      assert {:ok, _} =
               Deployments.create_deployment(%{
                 tenant_id: b.id,
                 app_template_id: template.id,
                 status: :pending
               })
    end
  end

  describe "existing_adoptions/1" do
    alias Homelab.Deployments.Adoption

    # After a failed run the original container is untouched and carries no
    # `homelab.managed` label, so discovery offers it again as if nothing had happened —
    # while a :pending deployment and an adopted template already exist.
    test "reports the space a container was already imported into" do
      space = insert(:tenant, name: "Home")
      assert {:ok, [result]} = Deployments.apply_adoption_plan(plan_for(), tenant_id: space.id)

      existing = Adoption.existing_adoptions(["homelab-pg", "never-imported"])

      assert %{deployment_id: id, space: "Home", status: :pending} = existing["homelab-pg"]
      assert id == result.deployment.id
      refute Map.has_key?(existing, "never-imported")
    end

    test "carries the active release, so a wedged one can be surfaced and abandoned" do
      space = insert(:tenant)
      assert {:ok, [result]} = Deployments.apply_adoption_plan(plan_for(), tenant_id: space.id)

      existing = Adoption.existing_adoptions(["homelab-pg"])
      assert existing["homelab-pg"].active_release.id == result.release.id
    end
  end

  describe "incomplete_imports/0" do
    alias Homelab.Deployments.Adoption

    test "lists adopted deployments that never got an external_id, and nothing else" do
      space = insert(:tenant)
      assert {:ok, [result]} = Deployments.apply_adoption_plan(plan_for(), tenant_id: space.id)

      # A finished adoption is not stranded.
      done_template = insert(:app_template, source: "adopted", slug: "adopted-done")

      {:ok, _done} =
        Deployments.create_deployment(%{
          tenant_id: space.id,
          app_template_id: done_template.id,
          status: :running,
          external_id: "abc123"
        })

      # Neither is a pending greenfield deployment.
      {:ok, _greenfield} =
        Deployments.create_deployment(%{
          tenant_id: space.id,
          app_template_id: insert(:app_template, source: "seeded").id,
          status: :pending
        })

      assert [only] = Adoption.incomplete_imports()
      assert only.id == result.deployment.id
      assert only.app_template.source == "adopted"
      assert only.tenant.id == space.id
    end

    # PRODUCTION.md's policy: a fix stops the bleeding and never rewrites existing rows,
    # because the platform cannot tell damage from a deliberate choice.
    test "is read-only — listing them deletes nothing" do
      space = insert(:tenant)
      assert {:ok, [result]} = Deployments.apply_adoption_plan(plan_for(), tenant_id: space.id)

      _ = Adoption.incomplete_imports()
      _ = Adoption.incomplete_imports()

      assert Homelab.Repo.get(Homelab.Deployments.Deployment, result.deployment.id)
    end
  end
end
