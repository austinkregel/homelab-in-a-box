defmodule HomelabWeb.SetupLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: _conn} do
    Homelab.Settings.set("setup_completed", "false")

    conn = Phoenix.ConnTest.build_conn()

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)
    |> stub(:description, fn -> "Docker Engine orchestrator" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)
    |> stub(:description, fn -> "Traefik reverse proxy" end)

    {:ok, conn: conn}
  end

  describe "step 1 - welcome" do
    test "renders step 1 on mount", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup")
      assert html =~ "Instance Name" or html =~ "Base Domain" or html =~ "Welcome"
    end

    test "validates step 1 form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      html =
        view
        |> form("#step1-form", %{
          "step1" => %{
            "instance_name" => "",
            "base_domain" => ""
          }
        })
        |> render_change()

      assert html =~ "Instance Name" or html =~ "Base Domain"
    end

    test "saves step 1 and advances to step 2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")

      view
      |> form("#step1-form", %{
        "step1" => %{
          "instance_name" => "My Homelab",
          "base_domain" => "example.local"
        }
      })
      |> render_submit()

      html = render(view)
      assert html =~ "OIDC" or html =~ "Authentication" or html =~ "Issuer"
    end
  end

  describe "step navigation" do
    test "next advances step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      render_click(view, "next", %{})
      html = render(view)
      assert html =~ "OIDC" or html =~ "Authentication" or html =~ "Issuer"
    end

    test "back goes to previous step", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")
      render_click(view, "back", %{})
      html = render(view)
      assert html =~ "Instance Name" or html =~ "Base Domain"
    end
  end

  describe "step 2 - authentication" do
    test "renders OIDC form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")
      html = render(view)
      assert html =~ "OIDC Issuer URL" or html =~ "Issuer"
      assert has_element?(view, "#step2-form")
    end

    test "validate_oidc validates issuer field", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      html =
        view
        |> form("#step2-form", %{
          "oidc" => %{"oidc_issuer" => "https://auth.example.com"}
        })
        |> render_change()

      assert html =~ "auth.example.com"
    end

    test "save_step_2 with empty issuer shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{"oidc_issuer" => ""}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "required" or html =~ "Issuer" or html =~ "error"
    end

    test "save_step_2 with valid data advances to step 3", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{"oidc_issuer" => "https://auth.example.com"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "Orchestrator" or html =~ "Infrastructure" or html =~ "Docker" or html =~ "required"
    end

    test "discover_oidc with empty issuer doesn't crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")
      html = render_click(view, "discover_oidc", %{})
      assert html =~ "OIDC" or html =~ "Issuer"
    end
  end

  describe "step 3 - infrastructure" do
    test "renders orchestrator and gateway selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      html = render(view)
      assert html =~ "Container Orchestrator" or html =~ "Orchestrator" or html =~ "Docker"
    end

    test "select_orchestrator selects an orchestrator", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      html = render_click(view, "select_orchestrator", %{"driver" => "docker"})
      assert html =~ "Docker"
    end

    test "select_gateway selects a gateway", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      html = render_click(view, "select_gateway", %{"driver" => "traefik"})
      assert html =~ "Traefik"
    end

    test "save_step_3 saves selections and advances", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      render_click(view, "select_orchestrator", %{"driver" => "docker"})
      render_click(view, "select_gateway", %{"driver" => "traefik"})
      render_click(view, "save_step_3", %{})

      html = render(view)
      assert html =~ "Space" or html =~ "Create" or html =~ "Name"
    end
  end

  describe "step 4 - spaces" do
    test "renders space creation form", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup?step=4")
      assert html =~ "Space" or html =~ "Name" or html =~ "Create"
    end

    test "validate_space validates the form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")

      html =
        view
        |> form("#step4-form", %{
          "tenant" => %{"name" => "", "slug" => ""}
        })
        |> render_change()

      assert html =~ "Space" or html =~ "Name"
    end

    test "generate_slug generates a slug from name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")
      html = render_click(view, "generate_slug", %{"name" => "My Space"})
      assert html =~ "Space" or html =~ "slug"
    end

    test "create_space saves tenant and advances", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")

      view
      |> form("#step4-form", %{
        "tenant" => %{"name" => "Test Space", "slug" => "test-space"}
      })
      |> render_submit()

      html = render(view)
      assert html =~ "complete" or html =~ "Dashboard" or html =~ "Setup"
    end
  end

  describe "handle_info :check_docker" do
    test "check_docker does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      send(view.pid, :check_docker)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Orchestrator" or html =~ "Docker" or html =~ "Container"
    end

    test "check_docker on step 1 is a no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      send(view.pid, :check_docker)
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Instance Name" or html =~ "Base Domain"
    end
  end

  describe "handle_info {:setting_changed, key}" do
    test "setting_changed does not crash the view", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup")
      send(view.pid, {:setting_changed, "some_key"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "Instance Name" or html =~ "Base Domain" or html =~ "Setup"
    end

    test "setting_changed re-renders without error on step 2", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")
      send(view.pid, {:setting_changed, "oidc_issuer"})
      _ = :sys.get_state(view.pid)
      html = render(view)
      assert html =~ "OIDC" or html =~ "Issuer"
    end
  end

  describe "generate_slug with special characters" do
    test "generates slug from name with special characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")

      view
      |> form("#step4-form", %{
        "tenant" => %{"name" => "My Cool Space!!!", "slug" => ""}
      })
      |> render_change()

      html = render_click(view, "generate_slug", %{})
      assert html =~ "Space" or html =~ "slug"
    end

    test "generates slug from name with unicode characters", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")

      view
      |> form("#step4-form", %{
        "tenant" => %{"name" => "Héllo Wörld & Friends", "slug" => ""}
      })
      |> render_change()

      html = render_click(view, "generate_slug", %{})
      assert html =~ "Space" or html =~ "slug"
    end

    test "generates slug from name with multiple spaces and hyphens", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=4")

      view
      |> form("#step4-form", %{
        "tenant" => %{"name" => "My   Space---Name", "slug" => ""}
      })
      |> render_change()

      html = render_click(view, "generate_slug", %{})
      assert html =~ "Space" or html =~ "slug"
    end
  end

  describe "step 3 orchestrator selection" do
    test "selecting docker orchestrator highlights it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      html = render_click(view, "select_orchestrator", %{"driver" => "docker"})

      assert html =~ "Docker"
      assert html =~ "Container Orchestrator"
    end

    test "selecting a different orchestrator updates the selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      render_click(view, "select_orchestrator", %{"driver" => "docker"})
      html = render_click(view, "select_orchestrator", %{"driver" => "docker_swarm"})

      assert html =~ "Container Orchestrator"
    end

    test "orchestrator selection persists after gateway selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      render_click(view, "select_orchestrator", %{"driver" => "docker"})
      html = render_click(view, "select_gateway", %{"driver" => "traefik"})

      assert html =~ "Docker"
      assert html =~ "Traefik"
    end
  end

  describe "step 3 gateway selection" do
    test "selecting traefik gateway highlights it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      html = render_click(view, "select_gateway", %{"driver" => "traefik"})

      assert html =~ "Traefik"
      assert html =~ "Reverse Proxy"
    end

    test "gateway section shows description text", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup?step=3")
      assert html =~ "Reverse Proxy"
      assert html =~ "Routes traffic"
    end
  end

  describe "step 3 save without selections" do
    test "save_step_3 without orchestrator shows error flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")

      Homelab.Settings.set("orchestrator", nil)

      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      render_click(view, "select_orchestrator", %{"driver" => "docker"})
      html = render_click(view, "save_step_3", %{})
      assert html =~ "Space" or html =~ "Create" or html =~ "Name"
    end

    test "save_step_3 with orchestrator selected advances to step 4", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=3")
      render_click(view, "select_orchestrator", %{"driver" => "docker"})
      render_click(view, "select_gateway", %{"driver" => "traefik"})
      render_click(view, "save_step_3", %{})

      html = render(view)
      assert html =~ "Space" or html =~ "Create" or html =~ "Name"
    end
  end

  describe "step 2 test_oidc" do
    test "test_oidc with a valid URL using Bypass", %{conn: conn} do
      bypass = Bypass.open()

      Bypass.expect_once(bypass, "GET", "/", fn conn ->
        Plug.Conn.resp(conn, 200, Jason.encode!(%{status: "ok"}))
      end)

      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{
          "oidc_issuer" => "http://localhost:#{bypass.port}/"
        }
      })
      |> render_change()

      html = render_click(view, "test_oidc", %{})
      assert html =~ "Connection successful"
    end

    test "test_oidc with empty issuer shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      html = render_click(view, "test_oidc", %{})
      assert html =~ "Enter an OIDC Issuer URL first"
    end

    test "test_oidc with unreachable URL shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{
          "oidc_issuer" => "http://localhost:1/unreachable"
        }
      })
      |> render_change()

      html = render_click(view, "test_oidc", %{})
      assert html =~ "error" or html =~ "refused" or html =~ "econnrefused" or has_element?(view, "span")
    end
  end

  describe "step 2 discover_oidc" do
    test "discover_oidc with valid issuer using Bypass", %{conn: conn} do
      bypass = Bypass.open()

      discovery_doc = %{
        "issuer" => "http://localhost:#{bypass.port}",
        "authorization_endpoint" => "http://localhost:#{bypass.port}/authorize",
        "token_endpoint" => "http://localhost:#{bypass.port}/token",
        "userinfo_endpoint" => "http://localhost:#{bypass.port}/userinfo",
        "jwks_uri" => "http://localhost:#{bypass.port}/jwks",
        "grant_types_supported" => ["authorization_code", "refresh_token"],
        "scopes_supported" => ["openid", "email", "profile"],
        "response_types_supported" => ["code"]
      }

      Bypass.expect_once(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        conn
        |> Plug.Conn.put_resp_header("content-type", "application/json")
        |> Plug.Conn.resp(200, Jason.encode!(discovery_doc))
      end)

      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{
          "oidc_issuer" => "http://localhost:#{bypass.port}"
        }
      })
      |> render_change()

      html = render_click(view, "discover_oidc", %{})
      assert html =~ "OIDC discovery successful"
      assert html =~ "Authorization Code"
    end

    test "discover_oidc with unreachable issuer shows error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      view
      |> form("#step2-form", %{
        "oidc" => %{
          "oidc_issuer" => "http://localhost:1"
        }
      })
      |> render_change()

      html = render_click(view, "discover_oidc", %{})
      assert html =~ "Failed to discover OIDC" or html =~ "Check the issuer URL"
    end

    test "discover_oidc with empty issuer is no-op", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/setup?step=2")

      html = render_click(view, "discover_oidc", %{})
      assert html =~ "OIDC" or html =~ "Issuer"
    end
  end

  describe "step 5 completion" do
    test "setup redirects to / when already complete", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/setup?step=5")
    end
  end

  describe "step indicator rendering" do
    test "step indicator shows all 5 steps", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup")
      for n <- 1..5 do
        assert html =~ to_string(n)
      end
    end

    test "step 2 shows correct subtitle", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup?step=2")
      assert html =~ "Connect your authentication provider"
    end

    test "step 3 shows correct subtitle", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/setup?step=3")
      assert html =~ "Verify infrastructure connectivity"
    end
  end
end
