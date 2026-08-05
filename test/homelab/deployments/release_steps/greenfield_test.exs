defmodule Homelab.Deployments.ReleaseSteps.GreenfieldTest do
  use Homelab.DataCase, async: false

  import Mox
  import Homelab.Factory

  alias Homelab.Deployments
  alias Homelab.Deployments.{Releases, ReleaseStep}

  alias Homelab.Deployments.ReleaseSteps.{
    AwaitHealth,
    DeployContainer,
    ProvisionCredentials,
    PublishIngress
  }

  setup :set_mox_global
  setup :verify_on_exit!

  defp clean_deployment do
    template = insert(:app_template, required_env: [], default_env: %{}, volumes: [], ports: [])
    insert(:deployment, app_template: template, external_id: nil)
  end

  defp ctx(deployment), do: %{release: nil, deployment: deployment}
  defp step(handle), do: %ReleaseStep{resource_handle: handle}

  describe "ProvisionCredentials" do
    test "generates shared credentials once across app and companion targets" do
      app = clean_deployment()
      companion = clean_deployment()

      s =
        step(%{
          "specs" => [
            %{"key" => "DB_PASSWORD", "kind" => "password", "length" => 16},
            %{"key" => "DB_USER", "kind" => "literal", "value" => "appuser"}
          ],
          "targets" => [app.id, companion.id]
        })

      assert {:ok, handle} = ProvisionCredentials.run(s, ctx(app))
      assert "DB_PASSWORD" in handle["provisioned"]

      app_secrets = Releases.decrypted_secrets(app.id)
      companion_secrets = Releases.decrypted_secrets(companion.id)

      # Same value propagated to both; literal honored; password is non-trivial.
      assert app_secrets["DB_PASSWORD"] == companion_secrets["DB_PASSWORD"]
      assert app_secrets["DB_USER"] == "appuser"
      assert String.length(app_secrets["DB_PASSWORD"]) == 16

      # Idempotent: re-running reuses the same password.
      {:ok, _} = ProvisionCredentials.run(s, ctx(app))
      assert Releases.decrypted_secrets(app.id)["DB_PASSWORD"] == app_secrets["DB_PASSWORD"]
    end
  end

  describe "DeployContainer" do
    test "deploys and records external_id on the deployment + handle" do
      app = clean_deployment()
      expect(Homelab.Mocks.Orchestrator, :deploy, fn _spec -> {:ok, "ext-123"} end)

      assert {:ok, handle} = DeployContainer.run(step(%{}), ctx(app))
      assert handle["external_id"] == "ext-123"
      assert handle["deployment_id"] == app.id

      reloaded = Deployments.get_deployment!(app.id)
      assert reloaded.external_id == "ext-123"
      assert reloaded.status == :deploying
    end

    test "compensate undeploys and clears the external_id (no orphan)" do
      app = clean_deployment()
      {:ok, _} = Deployments.update_deployment(app, %{external_id: "ext-9", status: :deploying})
      expect(Homelab.Mocks.Orchestrator, :undeploy, fn "ext-9" -> :ok end)

      s = step(%{"external_id" => "ext-9", "deployment_id" => app.id})
      assert :ok = DeployContainer.compensate(s, ctx(app))
      assert Deployments.get_deployment!(app.id).external_id == nil
    end

    # `do_deploy/1` marked the row `:failed` on BOTH failure branches; the saga handler
    # marked it on neither, and the difference is not cosmetic. A row left `:pending`
    # with no `external_id` is a row `Reconciler.converge_one/2` returns from
    # immediately — so a failed saga deploy sat "pending" forever, with no convergence
    # path and nothing on the deployment page saying why.
    test "an orchestrator failure marks the deployment failed with the reason" do
      app = clean_deployment()
      expect(Homelab.Mocks.Orchestrator, :deploy, fn _spec -> {:error, :image_not_found} end)

      assert {:error, {:deploy_failed, _id, :image_not_found}} =
               DeployContainer.run(step(%{}), ctx(app))

      reloaded = Deployments.get_deployment!(app.id)
      assert reloaded.status == :failed
      assert reloaded.error_message =~ "image_not_found"
    end

    # The other branch: the `with` had no `else` at all, so a spec-build error fell
    # straight through to the runner and never touched the row.
    test "a spec build failure marks the deployment failed with the reason" do
      template = insert(:app_template, required_env: ["MUST_HAVE_KEY"], default_env: %{})
      app = insert(:deployment, app_template: template, external_id: nil, status: :pending)

      assert {:error, {:spec_build_failed, {:missing_required_env, ["MUST_HAVE_KEY"]}}} =
               DeployContainer.run(step(%{}), ctx(app))

      reloaded = Deployments.get_deployment!(app.id)
      assert reloaded.status == :failed
      assert reloaded.error_message =~ "missing_required_env"
    end
  end

  describe "AwaitHealth" do
    test "returns healthy when the container reports running and healthy" do
      app = clean_deployment()
      {:ok, app} = Deployments.update_deployment(app, %{external_id: "ext-h"})

      stub(Homelab.Mocks.Orchestrator, :get_service, fn "ext-h" ->
        {:ok, %{id: "ext-h", state: :running, health: :healthy}}
      end)

      assert {:ok, %{"healthy" => true}} =
               AwaitHealth.run(step(%{"deployment_id" => app.id}), ctx(app))
    end

    test "times out when the container never becomes ready" do
      app = clean_deployment()
      {:ok, app} = Deployments.update_deployment(app, %{external_id: "ext-t"})

      Application.put_env(:homelab, :await_health_timeout_ms, 30)
      Application.put_env(:homelab, :await_health_interval_ms, 5)

      on_exit(fn ->
        Application.delete_env(:homelab, :await_health_timeout_ms)
        Application.delete_env(:homelab, :await_health_interval_ms)
      end)

      stub(Homelab.Mocks.Orchestrator, :get_service, fn _ ->
        {:ok, %{id: "ext-t", state: :pending, health: :starting}}
      end)

      assert {:error, {:health_timeout, _}} =
               AwaitHealth.run(step(%{"deployment_id" => app.id}), ctx(app))
    end
  end

  # This step attaches the WORKLOAD to the shared ingress network, and its compensation
  # detaches it. Both used to act on `homelab_<tenant>_<app>_net` — a network nothing was
  # ever on — so the moduledoc's promise that "a rolled-back release is never left
  # externally reachable" was false: Traefik kept routing to it.
  describe "PublishIngress" do
    test "attaches the app's container, and compensate detaches it" do
      app =
        insert(:deployment,
          app_template:
            insert(:app_template, required_env: [], default_env: %{}, volumes: [], ports: []),
          domain: "app.example.test",
          external_id: "container-x"
        )

      expect(Homelab.Mocks.Orchestrator, :publish, fn "container-x", _network -> :ok end)

      assert {:ok, %{"published" => true, "external_id" => "container-x"}} =
               PublishIngress.run(step(%{}), ctx(app))

      expect(Homelab.Mocks.Orchestrator, :unpublish, fn "container-x", _network -> :ok end)
      assert :ok = PublishIngress.compensate(step(%{"external_id" => "container-x"}), ctx(app))
    end

    test "compensation severs the container this step actually published" do
      # Even if the row has since been reset (which a rollback does), the handle still
      # names the container that was made reachable.
      app = clean_deployment()

      expect(Homelab.Mocks.Orchestrator, :unpublish, fn "stale-container", _network -> :ok end)

      assert :ok =
               PublishIngress.compensate(step(%{"external_id" => "stale-container"}), ctx(app))
    end
  end
end
