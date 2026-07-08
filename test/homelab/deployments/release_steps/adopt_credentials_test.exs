defmodule Homelab.Deployments.ReleaseSteps.AdoptCredentialsTest do
  use Homelab.DataCase, async: false

  import Homelab.Factory

  alias Homelab.Deployments.ReleaseSteps.AdoptCredentials
  alias Homelab.Deployments.Releases

  defmodule StubOps do
    @behaviour Homelab.Deployments.Migrate.ContainerOps

    @impl true
    def env(_id), do: {:ok, Application.get_env(:homelab, :stub_container_env, %{})}
    @impl true
    def image_env(_image), do: {:ok, Application.get_env(:homelab, :stub_image_env, %{})}
    @impl true
    def port_bindings(_id), do: {:ok, []}
    @impl true
    def restart_policy(_id), do: {:ok, "no"}
    @impl true
    def set_restart_policy(_id, _name), do: :ok
    @impl true
    def stop(_id, _t), do: :ok
    @impl true
    def start(_id), do: :ok
  end

  setup do
    Application.put_env(:homelab, :container_ops, StubOps)

    on_exit(fn ->
      Application.delete_env(:homelab, :container_ops)
      Application.delete_env(:homelab, :stub_container_env)
      Application.delete_env(:homelab, :stub_image_env)
    end)

    :ok
  end

  defp step(handle), do: %Homelab.Deployments.ReleaseStep{resource_handle: handle}

  test "imports user env (excluding image-baked pairs and PATH/HOME) as encrypted secrets" do
    deployment = insert(:deployment)

    Application.put_env(:homelab, :stub_container_env, %{
      "PATH" => "/usr/bin",
      "POSTGRES_PASSWORD" => "s3cret",
      "LANG" => "C.UTF-8"
    })

    Application.put_env(:homelab, :stub_image_env, %{
      "PATH" => "/usr/bin",
      "LANG" => "C.UTF-8"
    })

    ctx = %{release: nil, deployment: deployment}
    handle = step(%{"container" => "c1", "image" => "postgres:16"})

    assert {:ok, %{"imported_keys" => keys}} = AdoptCredentials.run(handle, ctx)
    assert keys == ["POSTGRES_PASSWORD"]

    assert Releases.decrypted_secrets(deployment.id) == %{"POSTGRES_PASSWORD" => "s3cret"}
  end

  test "zero user env is an honest success" do
    deployment = insert(:deployment)
    Application.put_env(:homelab, :stub_container_env, %{"PATH" => "/usr/bin"})
    Application.put_env(:homelab, :stub_image_env, %{"PATH" => "/usr/bin"})

    ctx = %{release: nil, deployment: deployment}
    handle = step(%{"container" => "c1", "image" => "img"})

    assert {:ok, %{"imported_keys" => []}} = AdoptCredentials.run(handle, ctx)
    assert Releases.decrypted_secrets(deployment.id) == %{}
  end

  test "compensate deletes exactly the imported keys" do
    deployment = insert(:deployment)
    Releases.put_secret(deployment.id, "POSTGRES_PASSWORD", "s3cret")
    Releases.put_secret(deployment.id, "KEEP_ME", "other")

    ctx = %{release: nil, deployment: deployment}
    handle = step(%{"imported_keys" => ["POSTGRES_PASSWORD"]})

    assert :ok = AdoptCredentials.compensate(handle, ctx)
    assert Releases.decrypted_secrets(deployment.id) == %{"KEEP_ME" => "other"}
  end
end
