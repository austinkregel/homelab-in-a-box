defmodule HomelabWeb.SharedTemplateRewriteTest do
  @moduledoc """
  App templates are shared by slug across every space. Two deploy paths used to write
  to an existing one, so deploying an app in one space changed what a DIFFERENT space's
  deployment of that app runs — silently, on its next redeploy.
  """
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  alias Homelab.Catalog
  alias Homelab.Deployments.Deployment
  alias Homelab.Repo

  @moduletag :capture_log

  setup :set_mox_global
  setup :verify_on_exit!

  setup do
    Homelab.Mocks.DnsProvider
    |> stub(:list_records, fn _zone -> {:ok, []} end)
    |> stub(:create_record, fn _zone, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:update_record, fn _zone, _id, _record -> {:ok, %{id: "rec_1"}} end)
    |> stub(:delete_record, fn _zone, _id -> :ok end)

    Homelab.Mocks.Orchestrator
    |> stub(:deploy, fn _spec -> {:ok, "svc_1"} end)
    |> stub(:stats, fn _id -> {:error, :not_found} end)
    |> stub(:logs, fn _id, _opts -> {:ok, ""} end)
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:get_service, fn _id -> {:error, :not_found} end)

    %{tenant: insert(:tenant)}
  end

  describe "custom image whose slug already exists" do
    test "the typed image reaches the deployment instead of being discarded", %{
      conn: conn,
      tenant: tenant
    } do
      # Typing `nginx:1.25` with a name that slugifies onto an existing template used to
      # deploy whatever the OLD template said, with no warning at all.
      existing =
        insert(:app_template,
          name: "Nginx",
          slug: "nginx",
          image: "nginx:1.18",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=custom")

      render_submit(view, "select_custom", %{"image" => "nginx:1.25", "name" => "Nginx"})

      render_click(view, "deploy", %{
        "tenant_id" => to_string(tenant.id),
        "exposure_mode" => "public",
        "domain" => "nginx.example.com"
      })

      deployment = Repo.get_by!(Deployment, app_template_id: existing.id)
      assert deployment.image_override == "nginx:1.25"

      # And the shared template is untouched, so no other space moved version.
      assert Repo.reload!(existing).image == "nginx:1.18"
    end

    test "no override is set when the existing template already runs that image", %{
      conn: conn,
      tenant: tenant
    } do
      existing =
        insert(:app_template,
          name: "Nginx",
          slug: "nginx",
          image: "nginx:1.25",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=custom")

      render_submit(view, "select_custom", %{"image" => "nginx:1.25", "name" => "Nginx"})

      render_click(view, "deploy", %{
        "tenant_id" => to_string(tenant.id),
        "exposure_mode" => "public",
        "domain" => "nginx2.example.com"
      })

      deployment = Repo.get_by!(Deployment, app_template_id: existing.id)
      assert deployment.image_override == nil
    end
  end

  describe "compose import whose service name collides" do
    test "a divergent service gets its own template rather than overwriting", %{
      conn: conn,
      tenant: tenant
    } do
      # Space A already runs redis:6 from a template slugged `redis`. Space B imports a
      # compose file with a `redis: image: redis:7` service. That used to rewrite the
      # shared template's image, moving space A to redis:7 on its next redeploy.
      shared_redis =
        insert(:app_template,
          name: "redis",
          slug: "redis",
          image: "redis:6",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      main =
        insert(:app_template,
          name: "ComposeMain",
          slug: "composemain-collide",
          image: "composemain:latest",
          default_env: %{},
          required_env: [],
          ports: [],
          volumes: []
        )

      {:ok, view, _html} = live(conn, ~p"/deploy/new?step=config&template_id=#{main.id}")

      render_click(view, "add_companion_custom", %{"image" => "redis:7"})

      view |> element("[phx-click=go_step][phx-value-step=review]") |> render_click()

      render_click(view, "deploy_compose", %{
        "tenant_id" => to_string(tenant.id),
        "domain" => "collide.example.com",
        "exposure_mode" => "public"
      })

      assert_redirect(view, "/")

      # The shared template is exactly as it was.
      assert Repo.reload!(shared_redis).image == "redis:6"

      # And the import got a template of its own for the version it asked for.
      {:ok, minted} =
        Catalog.list_app_templates()
        |> Enum.filter(&(&1.image == "redis:7"))
        |> case do
          [template] -> {:ok, template}
          other -> {:error, other}
        end

      assert minted.slug != "redis"
      assert String.starts_with?(minted.slug, "redis-")
    end
  end
end
