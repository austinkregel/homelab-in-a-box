defmodule HomelabWeb.WorkbenchLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)

    # The async ImageBuilder task (and quick-run) resolve the Docker client from
    # app env in a separate process, so route it globally for these tests.
    prev = Application.get_env(:homelab, :docker_client)
    Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
    on_exit(fn -> Application.put_env(:homelab, :docker_client, prev) end)

    {:ok, conn: conn, tenant: tenant}
  end

  defp wait_until(view, text, retries \\ 60) do
    _ = :sys.get_state(view.pid)
    html = render(view)

    cond do
      html =~ text ->
        html

      retries == 0 ->
        flunk("timed out waiting for #{inspect(text)}")

      true ->
        Process.sleep(20)
        wait_until(view, text, retries - 1)
    end
  end

  describe "mount / editor" do
    test "renders the editor with the Dockerfile and build controls", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/workbench")

      assert html =~ "Workbench"
      assert html =~ "Dockerfile"
      assert html =~ "Build image"
      assert html =~ "Workspace files"
    end

    test "add, rename, and remove build files", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workbench")

      html = render_click(view, "add_build_file", %{})
      assert html =~ "file1"

      html =
        render_change(view, "update_build_file", %{"name" => "app.sh", "content" => "echo hi"})

      assert html =~ "app.sh"

      html = render_click(view, "remove_build_file", %{"index" => "1"})
      refute html =~ "app.sh"
    end

    test "the Dockerfile tab cannot be removed", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workbench")
      html = render_click(view, "remove_build_file", %{"index" => "0"})
      assert html =~ "can&#39;t be removed" or html =~ "can't be removed"
    end
  end

  describe "uploads" do
    test "uploads a file into the workspace and reflects it in the quota bar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workbench")

      upload =
        file_input(view, "#upload-form", :context_files, [
          %{name: "extra.txt", content: "hello there", type: "text/plain"}
        ])

      html = render_upload(upload, "extra.txt")

      assert html =~ "extra.txt"
      # Quota bar shows some usage against the 1 GB quota.
      assert html =~ "/ 1.0 GB"

      # And it can be deleted again.
      html = render_click(view, "delete_workspace_file", %{"name" => "extra.txt"})
      refute html =~ "extra.txt"
    end
  end

  describe "build_image" do
    test "builds, registers the image, and shows the success + run panels", %{conn: conn} do
      stub(Homelab.Mocks.DockerClient, :build, fn _query, _context, on_event ->
        on_event.(%{"stream" => "Step 1/1 : FROM alpine:latest\n"})
        :ok
      end)

      Homelab.Mocks.Orchestrator
      |> stub(:list_volumes, fn -> {:ok, [%{name: "data", driver: "local", labels: %{}}]} end)
      |> stub(:list_networks, fn -> {:ok, [%{name: "bridge", driver: "bridge", labels: %{}}]} end)

      {:ok, view, _html} = live(conn, ~p"/workbench")

      view
      |> form("form[phx-submit=build_image]", %{"name" => "My App", "tag" => "latest"})
      |> render_submit()

      html = wait_until(view, "Configure &amp; deploy")

      assert html =~ "Step 1/1"
      assert html =~ "homelab-built/my-app:latest"
      assert html =~ "Quick run"
      # Deploy link points back to the Catalog page for the new template.
      assert html =~ "/catalog?template="
    end

    test "shows an error when the name is blank", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/workbench")

      html =
        view
        |> form("form[phx-submit=build_image]", %{"name" => "", "tag" => "latest"})
        |> render_submit()

      assert html =~ "A name is required"
    end
  end

  describe "quick run" do
    setup %{conn: conn} do
      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :build, fn _q, _c, on_event ->
        on_event.(%{"stream" => "built\n"})
        :ok
      end)

      Homelab.Mocks.Orchestrator
      |> stub(:list_volumes, fn -> {:ok, [%{name: "data", driver: "local", labels: %{}}]} end)
      |> stub(:list_networks, fn -> {:ok, [%{name: "bridge", driver: "bridge", labels: %{}}]} end)
      |> stub(:deploy, fn spec ->
        send(test_pid, {:deployed, spec})
        {:ok, "run-abc123"}
      end)
      |> stub(:get_service, fn _id ->
        {:ok,
         %{id: "run-abc123", name: "x", state: :running, replicas: 1, image: "i", labels: %{}}}
      end)
      |> stub(:logs, fn _id, _opts -> {:ok, "app running\n"} end)
      |> stub(:undeploy, fn _id -> :ok end)

      {:ok, view, _html} = live(conn, ~p"/workbench")

      view
      |> form("form[phx-submit=build_image]", %{"name" => "Runner", "tag" => "latest"})
      |> render_submit()

      wait_until(view, "Quick run")

      {:ok, view: view, test_pid: test_pid}
    end

    test "runs the built image with a workbench label and never homelab.managed", %{view: view} do
      render_click(view, "add_run_volume", %{})
      render_click(view, "add_run_env", %{})

      html =
        view
        |> element("#run-form")
        |> render_submit(%{
          "volumes" => %{"0" => %{"source" => "data", "container_path" => "/data"}},
          "env" => %{"0" => %{"key" => "FOO", "value" => "bar"}},
          "networks" => ["bridge"]
        })

      assert_received {:deployed, spec}
      assert spec.labels == %{"homelab.workbench" => "true"}
      refute Map.has_key?(spec.labels, "homelab.managed")
      assert spec.env == %{"FOO" => "bar"}
      assert spec.bridge_networks == ["bridge"]
      assert [%{source: "data", target: "/data", type: "volume"}] = spec.volumes

      assert html =~ "Stop run"
      assert html =~ "Run started" or html =~ "running"
    end

    test "stop_run undeploys and clears the run", %{view: view, test_pid: _pid} do
      view
      |> element("#run-form")
      |> render_submit(%{"networks" => ["bridge"]})

      assert_received {:deployed, _spec}

      html = render_click(view, "stop_run", %{})
      assert html =~ "Run here"
      assert html =~ "Run stopped"
    end
  end
end
