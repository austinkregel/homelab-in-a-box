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
        %{type: "bind", source: "/data", target: "/var/lib/postgresql/data", mountpoint: "/data", tier: :preserve}
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
end
