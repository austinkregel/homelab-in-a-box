defmodule HomelabWeb.SettingsLiveTest do
  use HomelabWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Homelab.Factory
  import Mox

  setup :set_mox_global
  setup :verify_on_exit!

  setup %{conn: conn} do
    tenant = insert(:tenant)
    template = insert(:app_template)

    Homelab.Mocks.Orchestrator
    |> stub(:list_services, fn -> {:ok, []} end)
    |> stub(:driver_id, fn -> "docker" end)
    |> stub(:display_name, fn -> "Docker" end)
    |> stub(:description, fn -> "Docker Engine orchestrator" end)

    Homelab.Mocks.Gateway
    |> stub(:driver_id, fn -> "traefik" end)
    |> stub(:display_name, fn -> "Traefik" end)
    |> stub(:description, fn -> "Traefik reverse proxy" end)

    Homelab.Settings.set("instance_name", "Test Lab")
    Homelab.Settings.set("base_domain", "lab.test.local")

    {:ok, conn: conn, tenant: tenant, template: template}
  end

  describe "mount" do
    test "renders settings page with general section", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Settings"
      assert html =~ "General"
    end

    test "shows section navigation sidebar", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      assert has_element?(view, "button", "General")
      assert has_element?(view, "button", "Authentication")
      assert has_element?(view, "button", "Infrastructure")
      assert has_element?(view, "button", "DNS & Domains")
      assert has_element?(view, "button", "Registries")
      assert has_element?(view, "button", "Users")
      assert has_element?(view, "button", "Danger Zone")
    end

    test "general section shows instance name and base domain", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings")
      assert html =~ "Test Lab"
      assert html =~ "lab.test.local"
    end
  end

  describe "section switching" do
    test "switch to authentication section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "authentication"})
      assert html =~ "Authentication"
      assert html =~ "OIDC Issuer"
    end

    test "switch to infrastructure section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})
      assert html =~ "Docker Connection"
      assert html =~ "Container Orchestrator"
      assert html =~ "Reverse Proxy"
    end

    test "switch to dns section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "dns"})
      assert html =~ "Domain Registrar" or html =~ "DNS"
    end

    test "switch to registries section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "registries"})
      assert html =~ "Registries"
      assert html =~ "GitHub Container Registry"
    end

    test "switch to users section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "users"})
      assert html =~ "Users"
    end

    test "switch to danger zone section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "danger_zone"})
      assert html =~ "Danger Zone"
      assert html =~ "Re-run Setup Wizard"
    end
  end

  describe "save_general" do
    test "saves general settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")

      html =
        view
        |> form("#general-form", %{
          "general" => %{
            "instance_name" => "Updated Lab",
            "base_domain" => "updated.test.local"
          }
        })
        |> render_submit()

      assert html =~ "General settings saved"
    end
  end

  describe "save_registry" do
    test "saves GHCR registry settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-ghcr-form", %{
          "registry" => %{"registry" => "ghcr", "ghcr_token" => "ghp_testtoken"}
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end

    test "saves ECR registry settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-ecr-form", %{
          "registry" => %{
            "registry" => "ecr",
            "ecr_access_key" => "AKIA123",
            "ecr_secret_key" => "secret123",
            "ecr_region" => "us-east-1"
          }
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end

    test "saves Docker Hub registry settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-dockerhub-form", %{
          "registry" => %{"registry" => "docker_hub", "docker_hub_token" => "dckr_token"}
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end
  end

  describe "save_orchestrator" do
    test "saves orchestrator selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "infrastructure"})
      html = render_click(view, "save_orchestrator", %{"driver" => "docker"})
      assert html =~ "Orchestrator updated"
    end
  end

  describe "save_gateway" do
    test "saves gateway selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "infrastructure"})
      html = render_click(view, "save_gateway", %{"driver" => "traefik"})
      assert html =~ "Gateway updated"
    end
  end

  describe "save_dns" do
    test "saves DNS settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "dns"})

      html =
        view
        |> form("#dns-settings-form", %{
          "dns" => %{
            "registrar" => "",
            "public_dns_provider" => "",
            "internal_dns_provider" => "",
            "unifi_host" => "",
            "pihole_url" => ""
          }
        })
        |> render_submit()

      assert html =~ "DNS settings saved"
    end
  end

  describe "update_user_role" do
    test "updates user role to member", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "users"})

      html =
        render_click(view, "update_user_role", %{
          "user_id" => to_string(user.id),
          "role" => "member"
        })

      assert html =~ "User role updated"
    end

    test "handles non-existent user", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "users"})

      html =
        render_click(view, "update_user_role", %{
          "user_id" => "999999",
          "role" => "member"
        })

      assert html =~ "User not found"
    end
  end

  describe "rerun_setup" do
    test "clears setup and redirects to setup page", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "danger_zone"})
      render_click(view, "rerun_setup", %{})
      assert_redirect(view, ~p"/setup")
    end
  end

  describe "infrastructure section details" do
    test "shows Docker orchestrator option", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})
      assert html =~ "Docker"
    end

    test "shows Traefik gateway option", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})
      assert html =~ "Traefik"
    end
  end

  describe "users section" do
    test "shows user list with emails", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "users"})
      assert html =~ user.email
    end
  end

  describe "save_dns with various provider configs" do
    test "saves DNS form with registrar selection", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "dns"})

      html =
        view
        |> form("#dns-settings-form", %{
          "dns" => %{
            "registrar" => "cloudflare",
            "public_dns_provider" => "cloudflare",
            "internal_dns_provider" => ""
          }
        })
        |> render_submit()

      assert html =~ "DNS settings saved"
    end

    test "saves UniFi credentials via DNS form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "dns"})

      html =
        view
        |> form("#dns-settings-form", %{
          "dns" => %{
            "registrar" => "",
            "public_dns_provider" => "",
            "internal_dns_provider" => "unifi",
            "unifi_host" => "https://192.168.1.1",
            "unifi_api_key" => "unifi_key_abc",
            "unifi_site" => "default",
            "unifi_api_version" => "new"
          }
        })
        |> render_submit()

      assert html =~ "DNS settings saved"
    end

    test "saves Pi-hole configuration via DNS form", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "dns"})

      html =
        view
        |> form("#dns-settings-form", %{
          "dns" => %{
            "registrar" => "",
            "public_dns_provider" => "",
            "internal_dns_provider" => "",
            "pihole_url" => "http://192.168.1.2:8053",
            "pihole_api_key" => "pihole_secret"
          }
        })
        |> render_submit()

      assert html =~ "DNS settings saved"
    end

    test "saves with Namecheap registrar selected", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "dns"})

      html =
        view
        |> form("#dns-settings-form", %{
          "dns" => %{
            "registrar" => "namecheap",
            "public_dns_provider" => "",
            "internal_dns_provider" => ""
          }
        })
        |> render_submit()

      assert html =~ "DNS settings saved"
    end
  end

  describe "handle_params with invalid section" do
    test "invalid section defaults to general", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings?section=nonexistent")
      assert html =~ "General"
      assert html =~ "Instance Name" or html =~ "Base Domain"
    end

    test "empty section defaults to general", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/settings?section=")
      assert html =~ "General"
    end
  end

  describe "save_registry with specific registry types" do
    test "saves GHCR with empty token does not crash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-ghcr-form", %{
          "registry" => %{"registry" => "ghcr", "ghcr_token" => ""}
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end

    test "saves GHCR with a token value", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-ghcr-form", %{
          "registry" => %{"ghcr_token" => "ghp_test_token_value"}
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end

    test "saves ECR with partial credentials", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registries"})

      html =
        view
        |> form("#registry-ecr-form", %{
          "registry" => %{
            "registry" => "ecr",
            "ecr_access_key" => "AKIA_PARTIAL",
            "ecr_secret_key" => "",
            "ecr_region" => "eu-west-1"
          }
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
    end
  end
end
