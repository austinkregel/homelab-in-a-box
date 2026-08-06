defmodule Homelab.Deployments.AdoptionRoutingTest do
  @moduledoc """
  Adoption is the THIRD planner, and the routing steps reached only the other two.

  `deploy_release/2` and `redeploy_netns_stack/1` both plan `:ensure_ingress_proxy`,
  `:sync_domain`, `:publish_dns` and `:publish_ingress` off the same predicates. The
  adoption path planned none of them, so an adopted deployment carrying a domain got
  no `Domain` row and no A records — the same workload deployed greenfield got both.

  The step ORDER is the other half of this. Adoption is a cutover with a backup gate,
  a quiesce of the original, a copy and a resume, and a name must not be advertised
  during the window when the original is deliberately stopped or before the
  replacement has been proven.
  """
  use Homelab.DataCase, async: false
  use Oban.Testing, repo: Homelab.ObanRepo

  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{AdoptionPlanner, Releases}

  defp review(name) do
    %{
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
  end

  # The reachable shape, and the one `Adoption` documents: the first apply creates the
  # deployment `:pending` with no domain, the operator gives it one, and the adoption is
  # re-run. `get_or_create_deployment/3` reuses the row deliberately — "by now the
  # operator may have deliberately changed them" — domain included.
  defp readopt(tenant, name, attrs) do
    plan = AdoptionPlanner.build_plan([review(name)])

    {:ok, [first]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)
    {:ok, _} = Releases.transition_release(first.release, :running, [:planning, :provisioning])
    {:ok, _} = Deployments.update_deployment(first.deployment, attrs)

    {:ok, [second]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)
    second
  end

  defp step_types(result) do
    result.release.id
    |> Releases.get_release()
    |> Map.fetch!(:steps)
    |> Enum.sort_by(& &1.position)
    |> Enum.map(& &1.type)
  end

  describe "a domainless adoption" do
    test "plans none of the routing steps" do
      tenant = insert(:tenant)
      plan = AdoptionPlanner.build_plan([review("homelab-pg")])

      assert {:ok, [result]} = Deployments.apply_adoption_plan(plan, tenant_id: tenant.id)

      types = step_types(result)

      refute :ensure_ingress_proxy in types
      refute :sync_domain in types
      refute :publish_dns in types
      refute :publish_ingress in types
    end
  end

  describe "an adoption carrying a domain" do
    test "claims the name it is served at" do
      tenant = insert(:tenant)
      result = readopt(tenant, "named-pg", %{domain: "named-pg.example.test"})

      types = step_types(result)

      assert :sync_domain in types
      assert :publish_dns in types
    end

    test "ensures the proxy at position 1, ahead of the backup gate" do
      # Same rule as greenfield: the proxy is a precondition of the route, not a
      # product of it. In an adoption that also means it is ensured before anything
      # has been quiesced, copied or cut over — there is nothing yet to unwind.
      tenant = insert(:tenant)
      result = readopt(tenant, "proxy-pg", %{domain: "proxy-pg.example.test"})

      assert [:ensure_ingress_proxy, :backup_verify | _] = step_types(result)
    end

    test "advertises the name only after the cutover has been verified" do
      # A cutover, not a greenfield deploy. Between `quiesce_old` and `adopt_container`
      # the ORIGINAL is deliberately stopped and the replacement does not exist yet, so
      # a name published in phase 1 resolves to a proxy with no backend for the length
      # of a data copy — and resolvers cache that. `verify_integrity` is adoption's
      # proof that the managed container came up on the migrated data, so the name is
      # claimed after it and never before.
      tenant = insert(:tenant)
      result = readopt(tenant, "tail-pg", %{domain: "tail-pg.example.test"})

      types = step_types(result)

      assert List.last(Enum.take_while(types, &(&1 != :sync_domain))) == :verify_integrity
      assert Enum.drop_while(types, &(&1 != :sync_domain)) == [:sync_domain, :publish_dns]
    end

    test "plans no publish_ingress for a :host adoption" do
      # `adopted_exposure/1` gives a plain adopted container `:host`, which is not
      # proxy-routed, so `publish_deployment/1` would decline to attach it at runtime.
      # Planning the step anyway is the "reports success for work it did not do"
      # defect the reachability gate exists to prevent.
      tenant = insert(:tenant)
      result = readopt(tenant, "hostmode-pg", %{domain: "hostmode-pg.example.test"})

      refute :publish_ingress in step_types(result)
    end

    test "grants reachability when the operator moves it behind the proxy" do
      tenant = insert(:tenant)

      result =
        readopt(tenant, "routed-pg", %{
          domain: "routed-pg.example.test",
          exposure_mode_override: "public"
        })

      types = step_types(result)

      assert :publish_ingress in types
      # Last of all: reachability is granted after the name resolves, so compensation
      # (which walks descending) severs the route before it removes the record.
      assert List.last(types) == :publish_ingress
    end
  end
end
