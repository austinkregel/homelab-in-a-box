defmodule Homelab.Deployments.ConfigOverridesTest do
  @moduledoc """
  The properties that used to be settable at create time and never again — or, for
  restart policy and replicas, never settable at all.
  """
  use ExUnit.Case, async: false

  alias Homelab.Deployments.{Access, Deployment, SpecBuilder}

  defp tenant do
    %Homelab.Tenants.Tenant{id: 1, slug: "friends", name: "Friends", status: :active, settings: %{}}
  end

  defp template(overrides \\ %{}) do
    Map.merge(
      %Homelab.Catalog.AppTemplate{
        id: 1,
        slug: "app",
        name: "App",
        version: "1.0",
        image: "app:1.0",
        exposure_mode: :sso_protected,
        auth_integration: true,
        default_env: %{},
        required_env: [],
        volumes: [],
        ports: [%{"container" => 8080, "protocol" => "tcp"}],
        resource_limits: %{},
        health_check: %{},
        depends_on: [],
        network_aliases: ["app"],
        command: ["serve"],
        entrypoint: ["/init"],
        source: "seeded"
      },
      overrides
    )
  end

  defp deployment(overrides \\ %{}) do
    t = Map.get(overrides, :app_template, template())

    Map.merge(
      %Deployment{
        id: 1,
        tenant: tenant(),
        tenant_id: 1,
        app_template: t,
        app_template_id: t.id,
        status: :running,
        domain: "app.homelab.local",
        env_overrides: %{},
        extra_routes: [],
        proxy_options: %{}
      },
      overrides
    )
  end

  describe "restart policy" do
    test "defaults to what both drivers used to hardcode" do
      assert Access.effective_restart_policy(deployment()) == "on-failure"
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.restart_policy == "on-failure"
    end

    test "an override reaches the spec" do
      d = deployment(%{restart_policy_override: "always"})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.restart_policy == "always"
    end

    test "only Docker's vocabulary is accepted" do
      for policy <- ~w(no on-failure always unless-stopped) do
        assert change(%{restart_policy_override: policy}).valid?, "#{policy} should be valid"
      end

      refute change(%{restart_policy_override: "sometimes"}).valid?
    end
  end

  describe "replicas" do
    test "defaults to the single task that was hardcoded" do
      assert Access.effective_replicas(deployment()) == 1
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.replicas == 1
    end

    test "an override reaches the spec" do
      assert {:ok, spec} = SpecBuilder.build(deployment(%{replicas_override: 3}))
      assert spec.replicas == 3
    end

    test "zero replicas is not a scale-to-nothing affordance" do
      refute change(%{replicas_override: 0}).valid?
    end

    test "scaling past one is rejected on Docker Engine" do
      # Engine cannot run a second task, so accepting the number would present as
      # "I asked for 3 and only one is serving".
      with_orchestrator(Homelab.Orchestrators.DockerEngine, fn ->
        refute change(%{replicas_override: 2}).valid?
        # One replica is what Engine already does, so it stays valid.
        assert change(%{replicas_override: 1}).valid?
      end)
    end

    test "scaling past one is allowed on Swarm" do
      with_orchestrator(Homelab.Orchestrators.DockerSwarm, fn ->
        assert change(%{replicas_override: 3}).valid?
      end)
    end

    test "scaling past one is rejected alongside host ports or host networking" do
      # Every task would bind the same host port; all but one fails to start, which
      # Swarm reports as a restarting task rather than as a conflict.
      with_orchestrator(Homelab.Orchestrators.DockerSwarm, fn ->
        refute change(%{replicas_override: 2, exposure_mode_override: "host"}).valid?
        refute change(%{replicas_override: 2, exposure_mode_override: "host_network"}).valid?
        assert change(%{replicas_override: 2, exposure_mode_override: "public"}).valid?
      end)
    end
  end

  describe "command and entrypoint" do
    test "inherit the template when unset" do
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.command == ["serve"]
      assert spec.entrypoint == ["/init"]
    end

    test "an override wins" do
      d = deployment(%{command_override: ["serve", "--debug"], entrypoint_override: ["/custom"]})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.command == ["serve", "--debug"]
      assert spec.entrypoint == ["/custom"]
    end

    test "an empty list is a value, not an absent one" do
      # Clearing an image's entrypoint is a real Docker instruction. If [] were treated
      # as nil it would silently inherit the template instead.
      d = deployment(%{command_override: [], entrypoint_override: []})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.command == []
      assert spec.entrypoint == []
    end
  end

  describe "network aliases" do
    test "inherit the template when unset" do
      assert {:ok, spec} = SpecBuilder.build(deployment())
      assert spec.network_aliases == ["app"]
    end

    test "an override wins, so a wrong adoption guess is fixable" do
      d = deployment(%{network_aliases_override: ["mysql", "db"]})
      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.network_aliases == ["mysql", "db"]
    end

    test "host networking still takes precedence over any alias" do
      # The daemon rejects a network-scoped alias in the host namespace; an override
      # must not be able to reintroduce one.
      d =
        deployment(%{
          exposure_mode_override: "host_network",
          network_aliases_override: ["mysql"]
        })

      assert {:ok, spec} = SpecBuilder.build(d)
      assert spec.network_aliases == []
    end
  end

  # --- helpers ---

  defp change(attrs) do
    Deployment.changeset(%Deployment{}, Map.merge(%{tenant_id: 1, app_template_id: 1}, attrs))
  end

  defp with_orchestrator(module, fun) do
    previous = Application.get_env(:homelab, :orchestrator)
    Application.put_env(:homelab, :orchestrator, module)

    try do
      fun.()
    after
      if previous,
        do: Application.put_env(:homelab, :orchestrator, previous),
        else: Application.delete_env(:homelab, :orchestrator)
    end
  end
end
