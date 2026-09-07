defmodule Homelab.Deployments.ReadinessTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments.Readiness
  alias Homelab.Deployments.Releases

  defp check(deployment, key), do: Enum.find(Readiness.checks(deployment), &(&1.key == key))

  describe "ingress gate" do
    test "passes for reverse-proxy access with a domain" do
      d =
        insert(:deployment,
          domain: "app.example.com",
          app_template: build(:app_template, exposure_mode: :sso_protected)
        )

      assert check(d, :ingress).status == :pass
    end

    test "gaps for a proxy mode with no domain" do
      d =
        insert(:deployment,
          domain: nil,
          app_template: build(:app_template, exposure_mode: :public)
        )

      assert check(d, :ingress).status == :gap
    end

    test "gaps for host access even with a domain" do
      d =
        insert(:deployment,
          domain: "app.example.com",
          app_template: build(:app_template, exposure_mode: :host)
        )

      assert check(d, :ingress).status == :gap
    end
  end

  describe "auth gate" do
    for mode <- [:sso_protected, :private] do
      test "passes for #{mode}" do
        d = insert(:deployment, app_template: build(:app_template, exposure_mode: unquote(mode)))
        assert check(d, :auth).status == :pass
      end
    end

    test "gaps for public (no auth)" do
      d = insert(:deployment, app_template: build(:app_template, exposure_mode: :public))
      assert check(d, :auth).status == :gap
    end
  end

  describe "backups gate" do
    test "gaps with no backup jobs" do
      d = insert(:deployment)
      assert check(d, :backups).status == :gap
    end

    test "gaps when jobs exist but none have completed" do
      d = insert(:deployment)
      insert(:backup_job, deployment: d, status: :failed)
      assert check(d, :backups).status == :gap
    end

    test "passes once a backup has completed" do
      d = insert(:deployment)
      insert(:backup_job, deployment: d, status: :completed)
      assert check(d, :backups).status == :pass
    end
  end

  describe "resilience gate" do
    test "passes with a healthcheck and resource limits" do
      d =
        insert(:deployment,
          app_template:
            build(:app_template,
              health_check: %{"path" => "/health"},
              resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512}
            )
        )

      assert check(d, :resilience).status == :pass
    end

    test "gaps without a healthcheck" do
      d =
        insert(:deployment,
          app_template:
            build(:app_template,
              health_check: %{},
              resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512}
            )
        )

      assert check(d, :resilience).status == :gap
    end

    test "gaps without explicit resource limits" do
      d =
        insert(:deployment,
          app_template:
            build(:app_template, health_check: %{"path" => "/health"}, resource_limits: %{})
        )

      assert check(d, :resilience).status == :gap
    end

    test "a per-deployment override closes the gate when the template lacks both" do
      d =
        insert(:deployment,
          app_template: build(:app_template, health_check: %{}, resource_limits: %{}),
          resource_limits_override: %{"memory_mb" => 512, "cpu_shares" => 1024},
          health_check_override: %{"path" => "/health"}
        )

      assert check(d, :resilience).status == :pass
    end
  end

  describe "ready?/1 and gaps/1" do
    test "ready? is true only when every gate passes" do
      d =
        insert(:deployment,
          domain: "app.example.com",
          app_template:
            build(:app_template,
              exposure_mode: :sso_protected,
              health_check: %{"path" => "/health"},
              resource_limits: %{"memory_mb" => 256, "cpu_shares" => 512}
            )
        )

      insert(:backup_job, deployment: d, status: :completed)

      assert Readiness.ready?(d)
      assert Readiness.gaps(d) == []
    end

    test "gaps/1 lists only the failing gates" do
      d =
        insert(:deployment,
          domain: nil,
          app_template: build(:app_template, exposure_mode: :public)
        )

      keys = Readiness.gaps(d) |> Enum.map(& &1.key)
      assert :ingress in keys
      assert :auth in keys
      assert :backups in keys
      refute Readiness.ready?(d)
    end
  end

  # This gate reads the donor's EFFECTIVE firewall env. Reading `env_overrides` alone
  # could never see the platform-derived value — deriving it means putting it in the
  # spec's env, never in the overrides — so the gate reported a permanent failure for
  # every correctly-configured donor and told the operator to re-do something that had
  # already happened. A check that cannot pass trains people to ignore it, and this is
  # the one that catches a real 502.
  describe "tunnel firewall gate" do
    setup do
      tenant = insert(:tenant)

      donor =
        insert(:deployment,
          tenant: tenant,
          app_template:
            build(:app_template,
              name: "Gluetun",
              netns_donor_kind: "gluetun",
              exposure_mode: :service,
              ports: []
            ),
          domain: nil,
          status: :running,
          external_id: "gluetun-1"
        )

      %{tenant: tenant, donor: donor}
    end

    defp tunneled_child(tenant, donor, overrides \\ %{}) do
      insert(
        :deployment,
        Map.merge(
          %{
            tenant: tenant,
            app_template:
              build(:app_template,
                name: "Sonarr",
                exposure_mode: :public,
                ports: [%{"internal" => 8989, "role" => "web"}]
              ),
            domain: "sonarr.example.com",
            network_parent_id: donor.id,
            netns_parent_external_id: "gluetun-1"
          },
          overrides
        )
      )
    end

    test "passes on the value the platform derives, with no operator action", ctx do
      child = tunneled_child(ctx.tenant, ctx.donor)

      assert check(Homelab.Deployments.get_deployment!(child.id), :netns_firewall).status ==
               :pass
    end

    test "an operator override that omits the port is a real gap", ctx do
      {:ok, _donor} =
        Homelab.Deployments.update_deployment(ctx.donor, %{
          env_overrides: %{"FIREWALL_INPUT_PORTS" => "1234"}
        })

      child = tunneled_child(ctx.tenant, ctx.donor)

      gate = check(Homelab.Deployments.get_deployment!(child.id), :netns_firewall)
      assert gate.status == :gap
      assert gate.detail =~ "8989"
    end

    test "a deployment on its own network is not asked about tunnels at all" do
      d = insert(:deployment, domain: "app.example.com")

      assert check(d, :netns_firewall) == nil
      assert check(d, :netns_donor) == nil
    end
  end

  # A donor is never a child, so none of the child gates above ever reach it — and it is
  # the deployment whose failure takes every container in its namespace down with it.
  describe "donor gates" do
    setup do
      %{tenant: insert(:tenant)}
    end

    defp donor(tenant, template_overrides \\ %{}, deployment_overrides \\ %{}) do
      template =
        build(
          :app_template,
          Map.merge(
            %{
              name: "Gluetun",
              netns_donor_kind: "gluetun",
              exposure_mode: :service,
              ports: [],
              default_env: %{},
              capabilities_add: ["NET_ADMIN"],
              devices: [%{"host_path" => "/dev/net/tun"}],
              health_check: %{"command" => "wget -q --spider https://example.com"}
            },
            template_overrides
          )
        )

      insert(
        :deployment,
        Map.merge(
          %{
            tenant: tenant,
            app_template: template,
            domain: nil,
            status: :running,
            external_id: "gluetun-1"
          },
          deployment_overrides
        )
      )
    end

    defp child_of(tenant, donor, name, ports) do
      insert(:deployment,
        tenant: tenant,
        app_template:
          build(:app_template,
            name: name,
            exposure_mode: :public,
            ports: ports,
            health_check: %{}
          ),
        domain: "#{String.downcase(name)}.example.com",
        network_parent_id: donor.id,
        netns_parent_external_id: donor.external_id
      )
    end

    test "a deployment with nothing in its namespace is asked none of them" do
      d = insert(:deployment)

      assert check(d, :netns_donor_privileges) == nil
      assert check(d, :netns_donor_firewall) == nil
      assert check(d, :netns_donor_health) == nil
      assert check(d, :netns_donor_route) == nil
    end

    test "a donor that claims no kind is not asked for a tunnel's privileges", ctx do
      d = donor(ctx.tenant, %{netns_donor_kind: nil})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_privileges) == nil
      assert check(d, :netns_donor_health) == nil
    end

    test "passes with NET_ADMIN and /dev/net/tun granted", ctx do
      d = donor(ctx.tenant)
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_privileges).status == :pass
    end

    test "gaps when NET_ADMIN is not granted", ctx do
      d = donor(ctx.tenant, %{capabilities_add: []})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_privileges)
      assert gate.status == :gap
      assert gate.detail =~ "NET_ADMIN"
    end

    test "gaps when /dev/net/tun is not passed through", ctx do
      d = donor(ctx.tenant, %{devices: []})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_privileges)
      assert gate.status == :gap
      assert gate.detail =~ "/dev/net/tun"
    end

    test "a per-deployment override grants what the template omits", ctx do
      d =
        donor(ctx.tenant, %{capabilities_add: [], devices: []}, %{
          capabilities_add_override: ["CAP_NET_ADMIN"],
          devices_override: [%{"host_path" => "/dev/net/tun"}]
        })

      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_privileges).status == :pass
    end

    test "the kill-switch gate passes on the ports the platform derives", ctx do
      d = donor(ctx.tenant)
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_firewall)
      assert gate.status == :pass
      assert gate.detail =~ "8989"
    end

    test "the kill-switch gate names the sibling being dropped", ctx do
      d = donor(ctx.tenant, %{}, %{env_overrides: %{"FIREWALL_INPUT_PORTS" => "8989"}})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])
      child_of(ctx.tenant, d, "Jackett", [%{"internal" => 9117}])

      gate = check(d, :netns_donor_firewall)
      assert gate.status == :gap
      assert gate.detail =~ "9117 (Jackett)"
      refute gate.detail =~ "Sonarr"
    end

    test "nothing to let in when no container in the namespace declares a port", ctx do
      d = donor(ctx.tenant)
      child_of(ctx.tenant, d, "Sonarr", [])

      assert check(d, :netns_donor_firewall).status == :pass
    end

    test "tunnel readiness gaps when the donor declares no healthcheck", ctx do
      d = donor(ctx.tenant, %{health_check: %{}})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_health)
      assert gate.status == :gap
      assert gate.detail =~ "barrier"
    end

    test "tunnel readiness passes on a declared healthcheck", ctx do
      d = donor(ctx.tenant)
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_health).status == :pass
    end

    test "passes when the donor carries only its children's routes", ctx do
      d = donor(ctx.tenant)
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_route).status == :pass
    end

    test "gaps when the donor is routed at a domain of its own", ctx do
      d = donor(ctx.tenant, %{exposure_mode: :sso_protected}, %{domain: "vpn.example.com"})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_route)
      assert gate.status == :gap
      assert gate.detail =~ "vpn.example.com"
    end

    test "a domain with no route in front of it is not a second way in", ctx do
      d = donor(ctx.tenant, %{exposure_mode: :service}, %{domain: "vpn.example.com"})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_route).status == :pass
    end

    test "no custom OpenVPN config is no question rather than a passing answer", ctx do
      d = donor(ctx.tenant, %{default_env: %{"VPN_SERVICE_PROVIDER" => "mullvad"}})
      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_vpn_config) == nil
    end

    test "gaps on a custom config named beside a built-in provider", ctx do
      d =
        donor(ctx.tenant, %{
          default_env: %{
            "VPN_SERVICE_PROVIDER" => "mullvad",
            "OPENVPN_CUSTOM_CONFIG" => "/gluetun/custom.conf"
          }
        })

      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      gate = check(d, :netns_donor_vpn_config)
      assert gate.status == :gap
      assert gate.detail =~ "mullvad"
    end

    test "passes once the provider is custom", ctx do
      d =
        donor(ctx.tenant, %{
          default_env: %{
            "VPN_SERVICE_PROVIDER" => "custom",
            "OPENVPN_CUSTOM_CONFIG" => "/gluetun/custom.conf"
          }
        })

      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_vpn_config).status == :pass
    end

    test "an override naming the custom config is read the same way", ctx do
      d =
        donor(ctx.tenant, %{default_env: %{"VPN_SERVICE_PROVIDER" => "mullvad"}}, %{
          env_overrides: %{"OPENVPN_CUSTOM_CONFIG" => "/gluetun/custom.conf"}
        })

      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])

      assert check(d, :netns_donor_vpn_config).status == :gap
    end

    test "a provider that arrives as a secret leaves the question unanswered", ctx do
      d =
        donor(ctx.tenant, %{
          default_env: %{
            "VPN_SERVICE_PROVIDER" => "mullvad",
            "OPENVPN_CUSTOM_CONFIG" => "/gluetun/custom.conf"
          }
        })

      child_of(ctx.tenant, d, "Sonarr", [%{"internal" => 8989}])
      Releases.put_secret(d.id, "VPN_SERVICE_PROVIDER", "custom")

      assert check(d, :netns_donor_vpn_config) == nil
    end
  end
end
