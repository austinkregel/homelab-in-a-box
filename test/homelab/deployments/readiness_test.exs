defmodule Homelab.Deployments.ReadinessTest do
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments.Readiness

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
end
