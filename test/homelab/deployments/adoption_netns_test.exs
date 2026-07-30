defmodule Homelab.Deployments.AdoptionNetnsTest do
  @moduledoc """
  Adopting a stack where one container holds the network for the others — gluetun plus the
  apps behind it, which is how a VPN'd homelab is actually built.

  This used to be refused outright (`:netns_child_not_adoptable`), so importing such a
  stack failed on the first tunneled app and there was no way to bring it in. The refusal
  existed for a real reason: adopting the child without its donor puts it on the tenant
  network instead of inside the tunnel, and it reports success while leaking from the
  first second. So the fix is resolution and ordering, not permission.
  """
  use Homelab.DataCase, async: false
  use Oban.Testing, repo: Homelab.ObanRepo

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{AdoptionPlanner, Netns, Releases}

  @gluetun_id "68aa952bd68a4d1e71d26a4bed7dd14d54b210e4611c8ac3daa83427f2e594e0"

  defp review(name, overrides) do
    Map.merge(
      %{
        name: name,
        image: "#{name}:latest",
        user: nil,
        restart_policy: "unless-stopped",
        container_id: "old-#{name}",
        aliases: [],
        command: nil,
        entrypoint: nil,
        host_network: false,
        netns_parent_container_id: nil,
        preserve: [
          %{
            type: "bind",
            source: "/srv/#{name}",
            target: "/config",
            mountpoint: "/srv/#{name}",
            tier: :preserve
          }
        ],
        rebuildable: [],
        out_of_scope: []
      },
      overrides
    )
  end

  defp donor_review, do: review("gluetun", %{container_id: @gluetun_id})

  defp child_review(name \\ "sabnzbd"),
    do: review(name, %{netns_parent_container_id: @gluetun_id})

  describe "planning" do
    test "a child is planned as :service, never as a host mode" do
      # `Netns` refuses both host modes for a child, and adoption writes exposure onto the
      # TEMPLATE — which is where that guard reads it. Planned as `:host` (what every
      # non-host-network service used to get) the deployment is simply unsavable.
      plan = AdoptionPlanner.build_plan([child_review()])
      [service] = plan.services

      assert service.template_attrs.exposure_mode == :service
    end

    test "a service that is not in a namespace still gets :host" do
      plan = AdoptionPlanner.build_plan([review("sonarr", %{})])
      [service] = plan.services

      assert service.template_attrs.exposure_mode == :host
    end

    test "the donor is ordered before its children, whatever order they were selected in" do
      plan = AdoptionPlanner.build_plan([child_review(), donor_review()])

      assert Enum.map(plan.services, & &1.name) == ["gluetun", "sabnzbd"]
    end

    test "each service carries its own container id, so a donor can be identified" do
      plan = AdoptionPlanner.build_plan([donor_review()])
      [service] = plan.services

      assert service.container_id == @gluetun_id
    end
  end

  describe "applying" do
    test "the child is adopted INTO the donor's namespace" do
      tenant = insert(:tenant)
      plan = AdoptionPlanner.build_plan([donor_review(), child_review()])

      assert {:ok, [donor_result, child_result]} =
               Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      assert donor_result.service == "gluetun"
      assert child_result.service == "sabnzbd"

      assert child_result.deployment.network_parent_id == donor_result.deployment.id
      assert Netns.child?(child_result.deployment)
      refute Netns.child?(donor_result.deployment)
    end

    test "the child's cutover waits for the donor's managed container" do
      # The child's create payload embeds the donor's CONTAINER id, so it cannot be built
      # until the donor has one. The barrier sits immediately before the cutover rather
      # than at the top of the release, so both data copies still overlap.
      tenant = insert(:tenant)
      plan = AdoptionPlanner.build_plan([donor_review(), child_review()])

      {:ok, [donor_result, child_result]} =
        Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      types =
        child_result.release.id
        |> Releases.get_release()
        |> Map.fetch!(:steps)
        |> Enum.map(& &1.type)

      assert :await_health in types

      wait =
        child_result.release.id
        |> Releases.get_release()
        |> Map.fetch!(:steps)
        |> Enum.find(&(&1.type == :await_health))

      assert wait.resource_handle["deployment_id"] == donor_result.deployment.id

      # Waiting behind another service's data copy, not behind one container starting.
      assert wait.resource_handle["timeout_ms"] > 120_000

      assert Enum.take_while(types, &(&1 != :await_health)) == [
               :backup_verify,
               :quiesce_old,
               :migrate_volume,
               :resume_old
             ]

      assert Enum.drop_while(types, &(&1 != :await_health)) |> Enum.drop(1) |> hd() ==
               :adopt_credentials
    end

    test "the donor's own release gains no wait" do
      tenant = insert(:tenant)
      plan = AdoptionPlanner.build_plan([donor_review(), child_review()])

      {:ok, [donor_result, _child]} =
        Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      types =
        donor_result.release.id
        |> Releases.get_release()
        |> Map.fetch!(:steps)
        |> Enum.map(& &1.type)

      refute :await_health in types
    end

    test "two children of one donor both land in its namespace" do
      tenant = insert(:tenant)

      plan =
        AdoptionPlanner.build_plan([
          child_review("sabnzbd"),
          donor_review(),
          child_review("radarr")
        ])

      assert {:ok, results} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      by_name = Map.new(results, &{&1.service, &1.deployment})
      donor = by_name["gluetun"]

      assert by_name["sabnzbd"].network_parent_id == donor.id
      assert by_name["radarr"].network_parent_id == donor.id
    end

    test "a donor left out of the import is refused, and says so" do
      # Still the right answer: there is nothing on an adopted donor's row that points back
      # at the original container id a child's NetworkMode names, so a donor outside the
      # plan cannot be resolved — and adopting the child regardless would put its traffic
      # outside the tunnel while reporting success.
      tenant = insert(:tenant)
      plan = AdoptionPlanner.build_plan([child_review()])

      assert {:error, {"sabnzbd", {:netns_donor_not_selected, @gluetun_id}}} =
               Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      assert Homelab.Repo.aggregate(Homelab.Deployments.Deployment, :count) == 0
    end

    test "a short donor id still resolves" do
      tenant = insert(:tenant)

      plan =
        AdoptionPlanner.build_plan([
          review("gluetun", %{container_id: @gluetun_id}),
          review("sabnzbd", %{
            netns_parent_container_id: String.slice(@gluetun_id, 0, 12)
          })
        ])

      assert {:ok, [donor_result, child_result]} =
               Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      assert child_result.deployment.network_parent_id == donor_result.deployment.id
    end
  end
end
