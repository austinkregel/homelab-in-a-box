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

  describe "self-hosted registry section" do
    test "renders the registry section with operator instructions", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "registry"})

      assert html =~ "Self-hosted registry"
      assert html =~ "docker login registry."
      assert html =~ "registry-mirrors"
    end

    test "save_self_hosted_registry persists credentials and options", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registry"})

      html =
        view
        |> form("#self-hosted-registry-form", %{
          "registry" => %{
            "username" => "bob",
            "password" => "s3cret",
            "host_ip" => "203.0.113.9",
            "mirror_enabled" => "true"
          }
        })
        |> render_submit()

      assert html =~ "Registry settings saved"
      assert Homelab.Settings.get("registry_username") == "bob"
      assert Homelab.Settings.get("registry_mirror_enabled") == "true"
    end

    test "enable_registry without credentials shows a validation flash", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registry"})

      html = render_click(view, "enable_registry", %{})
      assert html =~ "Set a username and password"
      assert Homelab.Settings.get("registry_enabled") == "false"
    end

    test "disable_registry stops the registry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "registry"})

      html = render_click(view, "disable_registry", %{})
      assert html =~ "Registry stopped"
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

  describe "catalog section" do
    setup do
      on_exit(fn -> Homelab.Settings.evict("enabled_catalogs") end)
      :ok
    end

    test "lists every catalog source with os_bases enabled by default", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "catalog"})

      assert html =~ "OS bases"
      assert html =~ "Curated"
      assert html =~ "Hotio"
    end

    test "toggling a source persists the enabled list", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "catalog"})

      render_click(view, "toggle_catalog", %{"id" => "curated"})

      assert "curated" in Jason.decode!(Homelab.Settings.get("enabled_catalogs"))
    end
  end

  describe "orphan sweep controls" do
    setup do
      on_exit(fn -> Homelab.Settings.evict("reconciler_sweep_mode") end)
      :ok
    end

    test "renders the sweep-mode control defaulting to sever-only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "danger_zone"})

      assert html =~ "Orphan sweep"
      assert html =~ "Sever only"
      assert html =~ "Armed"
      assert html =~ "Paused"
    end

    test "save_sweep_mode persists a valid mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "danger_zone"})

      render_click(view, "save_sweep_mode", %{"mode" => "armed"})
      assert Homelab.Settings.get("reconciler_sweep_mode") == "armed"
    end

    test "save_sweep_mode rejects an invalid mode", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "danger_zone"})

      html = render_click(view, "save_sweep_mode", %{"mode" => "nonsense"})
      assert html =~ "Unknown sweep mode"
      assert Homelab.Settings.get("reconciler_sweep_mode", "sever_only") == "sever_only"
    end

    test "renders an empty orphan panel when the reconciler is not running", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "danger_zone"})
      # No orphan rows, no crash — list_orphans/0 returns [] when not running.
      refute html =~ "Orphaned containers"
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

    test "save_storage_roots persists and takes effect immediately", %{conn: conn} do
      on_exit(fn ->
        Homelab.Settings.evict("adoption_root")
        Homelab.Settings.evict("managed_root")
        Application.delete_env(:homelab, :adoption_root)
        Application.delete_env(:homelab, :managed_root)
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "infrastructure"})

      view
      |> form("#storage-roots-form", %{
        "storage" => %{"adoption_root" => "/srv/appdata", "managed_root" => "/mnt/tank/managed"}
      })
      |> render_submit()

      # Persisted...
      assert Homelab.Settings.get("adoption_root") == "/srv/appdata"
      assert Homelab.Settings.get("managed_root") == "/mnt/tank/managed"

      # ...and the modules read the new values right away (cache-only lookup).
      assert Homelab.Deployments.AdoptionPolicy.adoption_root() == "/srv/appdata"
      assert Homelab.Deployments.PermanentHome.managed_root() == "/mnt/tank/managed"
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

  describe "import section" do
    test "renders the import section", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "import"})

      assert html =~ "Import existing stack"
      assert html =~ "Discover"
    end

    test "shows an error when discovery cannot reach the daemon", %{conn: conn} do
      # Default test docker_client is the UnavailableClient, so discovery errors.
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "import"})

      html = render_click(view, "run_discovery", %{})
      assert html =~ "Discovery failed"
    end

    test "discovers an in-scope service and previews its migration plan", %{conn: conn} do
      prev = Application.get_env(:homelab, :docker_client)
      prev_root = Application.get_env(:homelab, :adoption_root)
      Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
      Application.put_env(:homelab, :adoption_root, "/srv/homelab")
      Homelab.Settings.evict("adoption_root")

      on_exit(fn ->
        restore_docker_client(prev)
        Homelab.Settings.evict("adoption_root")

        if prev_root,
          do: Application.put_env(:homelab, :adoption_root, prev_root),
          else: Application.delete_env(:homelab, :adoption_root)
      end)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "abc123"}]}

        "/containers/abc123/json", _opts ->
          {:ok,
           %{
             "Id" => "abc123",
             "Name" => "/homelab-postgres",
             "Config" => %{"Image" => "postgres:16.2", "User" => "999:999"},
             "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}},
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/homelab/appdata/pg",
                 "Destination" => "/var/lib/postgresql/data",
                 "RW" => true
               }
             ]
           }}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "import"})

      html = render_click(view, "run_discovery", %{})
      assert html =~ "homelab-postgres"
      assert html =~ "preserve"

      html = render_click(view, "preview_plan", %{})
      assert html =~ "Phase 1"
      assert html =~ "backup_verify"
      assert html =~ "adopt_container"
    end

    test "apply_import creates a deployment + release and shows the started panel", %{conn: conn} do
      tenant = insert(:tenant)

      prev = Application.get_env(:homelab, :docker_client)
      prev_root = Application.get_env(:homelab, :adoption_root)
      Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
      Application.put_env(:homelab, :adoption_root, "/srv/appdata")
      Homelab.Settings.evict("adoption_root")

      on_exit(fn ->
        restore_docker_client(prev)
        Homelab.Settings.evict("adoption_root")

        if prev_root,
          do: Application.put_env(:homelab, :adoption_root, prev_root),
          else: Application.delete_env(:homelab, :adoption_root)
      end)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/containers/json?all=true", _opts ->
          {:ok, [%{"Id" => "abc123"}]}

        "/containers/abc123/json", _opts ->
          {:ok,
           %{
             "Id" => "abc123",
             "Name" => "/homelab-postgres",
             "Config" => %{"Image" => "postgres:16.2", "User" => "999:999"},
             "HostConfig" => %{"RestartPolicy" => %{"Name" => "always"}},
             "State" => %{"Status" => "running"},
             "Mounts" => [
               %{
                 "Type" => "bind",
                 "Source" => "/srv/appdata/pg",
                 "Destination" => "/var/lib/postgresql/data",
                 "RW" => true
               }
             ]
           }}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "import"})
      render_click(view, "run_discovery", %{})
      render_click(view, "preview_plan", %{})
      render_click(view, "select_import_tenant", %{"tenant_id" => to_string(tenant.id)})

      html = render_click(view, "apply_import", %{})
      assert html =~ "Import started"

      deployment = Homelab.Repo.get_by(Homelab.Deployments.Deployment, tenant_id: tenant.id)
      assert deployment
      assert deployment.status == :pending
      assert Homelab.Deployments.Releases.get_active_release(deployment.id)
    end
  end

  defp restore_docker_client(nil), do: Application.delete_env(:homelab, :docker_client)
  defp restore_docker_client(val), do: Application.put_env(:homelab, :docker_client, val)
end
