defmodule HomelabWeb.DeploymentVersionTest do
  @moduledoc """
  The version picker on a deployment's Settings tab — the answer to "I deployed this
  six months ago and there is no way off the version I picked".
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Catalog.TagInfo
  alias Homelab.Deployments
  alias Homelab.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  defmodule HubStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:search, :list_tags]

    def list_tags(_repo, _opts) do
      {:ok,
       [
         %TagInfo{tag: "16.11.0", last_updated: "2026-01-01T00:00:00Z"},
         %TagInfo{tag: "17.0.0", last_updated: "2026-06-01T00:00:00Z"}
       ]}
    end
  end

  defmodule ErroringStub do
    @moduledoc false
    def driver_id, do: "dockerhub"
    def capabilities, do: [:list_tags]
    def list_tags(_repo, _opts), do: {:error, {:http_error, 429}}
  end

  setup do
    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:undeploy, fn _id -> :ok end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)

    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    previous_registries = Application.get_env(:homelab, :registries)
    previous_domain = Application.get_env(:homelab, :base_domain)
    Application.put_env(:homelab, :registries, [HubStub])
    Application.put_env(:homelab, :base_domain, "test.local")

    on_exit(fn ->
      restore(:registries, previous_registries)
      restore(:base_domain, previous_domain)
    end)

    template = insert(:app_template, name: "GitLab", image: "gitlab/gitlab-ce:16.11.0")
    deployment = insert(:deployment, app_template: template, status: :running)

    %{deployment: deployment, template: template}
  end

  defp restore(key, nil), do: Application.delete_env(:homelab, key)
  defp restore(key, value), do: Application.put_env(:homelab, key, value)

  defp settings_view(conn, deployment) do
    {:ok, view, _html} = live(conn, ~p"/deployments/#{deployment.id}")
    render_click(view, "switch_tab", %{"tab" => "settings"})
    view
  end

  describe "showing the running version" do
    test "an unpinned deployment reports it follows the catalog", %{
      conn: conn,
      deployment: deployment
    } do
      html = settings_view(conn, deployment) |> render()

      assert html =~ "gitlab/gitlab-ce:16.11.0"
      assert html =~ "Catalog default"
    end

    test "a pinned deployment says so, and shows what it diverged from", %{
      conn: conn,
      deployment: deployment
    } do
      {:ok, pinned} =
        Deployments.update_deployment(deployment, %{image_override: "gitlab/gitlab-ce:17.0.0"})

      html = settings_view(conn, pinned) |> render()

      assert html =~ "gitlab/gitlab-ce:17.0.0"
      assert html =~ "Pinned"
      # The catalog default stays visible, so "what am I diverged from" is answerable.
      assert html =~ "gitlab/gitlab-ce:16.11.0"
    end
  end

  describe "changing the version" do
    test "saving a new reference pins the deployment and recreates it", %{
      conn: conn,
      deployment: deployment
    } do
      view = settings_view(conn, deployment)
      render_click(view, "start_version_edit", %{})

      html =
        view
        |> form("#version-form", %{"version" => %{"image" => "gitlab/gitlab-ce:17.0.0"}})
        |> render_submit()

      assert html =~ "Now running gitlab/gitlab-ce:17.0.0"
      assert Repo.reload!(deployment).image_override == "gitlab/gitlab-ce:17.0.0"
    end

    test "the shared template is untouched, so no sibling moves version", %{
      conn: conn,
      deployment: deployment,
      template: template
    } do
      # The entire reason the override lives on the deployment.
      other_tenant = insert(:tenant)
      sibling = insert(:deployment, app_template: template, tenant: other_tenant)

      view = settings_view(conn, deployment)
      render_click(view, "start_version_edit", %{})

      view
      |> form("#version-form", %{"version" => %{"image" => "gitlab/gitlab-ce:17.0.0"}})
      |> render_submit()

      assert Repo.reload!(template).image == "gitlab/gitlab-ce:16.11.0"
      assert Repo.reload!(sibling).image_override == nil
    end

    test "typing the catalog's own image back in means follow, not pin", %{
      conn: conn,
      deployment: deployment
    } do
      {:ok, pinned} =
        Deployments.update_deployment(deployment, %{image_override: "gitlab/gitlab-ce:17.0.0"})

      view = settings_view(conn, pinned)
      render_click(view, "start_version_edit", %{})

      view
      |> form("#version-form", %{"version" => %{"image" => "gitlab/gitlab-ce:16.11.0"}})
      |> render_submit()

      assert Repo.reload!(deployment).image_override == nil
    end

    test "reset returns the deployment to the catalog default", %{
      conn: conn,
      deployment: deployment
    } do
      {:ok, pinned} =
        Deployments.update_deployment(deployment, %{image_override: "gitlab/gitlab-ce:17.0.0"})

      view = settings_view(conn, pinned)
      render_click(view, "start_version_edit", %{})
      html = render_click(view, "reset_version", %{})

      assert html =~ "Reset to the catalog default"
      assert Repo.reload!(deployment).image_override == nil
    end

    test "a malformed reference is refused rather than sent to the daemon", %{
      conn: conn,
      deployment: deployment
    } do
      view = settings_view(conn, deployment)
      render_click(view, "start_version_edit", %{})

      html =
        view
        |> form("#version-form", %{"version" => %{"image" => "not a valid ref"}})
        |> render_submit()

      assert html =~ "Could not save"
      assert Repo.reload!(deployment).image_override == nil
    end

    test "the operator is warned before committing", %{conn: conn, deployment: deployment} do
      view = settings_view(conn, deployment)
      html = render_click(view, "start_version_edit", %{})

      assert html =~ "recreates the container"
      # The GitLab case: the expensive mistake is not recoverable from this screen.
      assert html =~ "one version at a time"
    end
  end

  describe "tag discovery" do
    test "offers the registry's tags, and picking one fills the field", %{
      conn: conn,
      deployment: deployment
    } do
      view = settings_view(conn, deployment)
      render_click(view, "start_version_edit", %{})

      # The fetch is async; wait for it to land.
      assert render_async(view) =~ "17.0.0"

      html = render_click(view, "select_tag", %{"tag" => "17.0.0"})
      assert html =~ "gitlab/gitlab-ce:17.0.0"

      # Picking a tag fills the field; it does not save on its own.
      assert Repo.reload!(deployment).image_override == nil
    end

    test "a registry that will not answer degrades to the text field", %{
      conn: conn,
      deployment: deployment
    } do
      Application.put_env(:homelab, :registries, [ErroringStub])

      view = settings_view(conn, deployment)
      render_click(view, "start_version_edit", %{})

      html = render_async(view)
      assert html =~ "registry did not answer"
      # The control that always works is still there.
      assert html =~ "version[image]"
    end
  end

  describe "the overview no longer dead-ends" do
    test "the image links to where it can be changed", %{conn: conn, deployment: deployment} do
      {:ok, _view, html} = live(conn, ~p"/deployments/#{deployment.id}")

      assert html =~ "gitlab/gitlab-ce:16.11.0"
      assert html =~ "Change →"
    end
  end
end
