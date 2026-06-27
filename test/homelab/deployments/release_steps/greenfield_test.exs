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

  describe "PublishIngress" do
    test "publishes the network and compensate unpublishes" do
      app = clean_deployment()
      expect(Homelab.Mocks.Orchestrator, :publish, fn "net-x" -> :ok end)

      assert {:ok, %{"network" => "net-x", "published" => true}} =
               PublishIngress.run(step(%{"network" => "net-x"}), ctx(app))

      expect(Homelab.Mocks.Orchestrator, :unpublish, fn "net-x" -> :ok end)
      assert :ok = PublishIngress.compensate(step(%{"network" => "net-x"}), ctx(app))
    end
  end
end
