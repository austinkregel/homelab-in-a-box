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

  describe "adoption root" do
    alias Homelab.Deployments.AdoptionPolicy

    # The adoption root is the ONE thing that decides whether discovery sees anything, and
    # it had no UI -- so a scan that matched nothing looked like "nothing to import" rather
    # than "you are looking in the wrong place". Its default is System.user_home() <>
    # "/homelab", which inside the app's own container is /root/homelab: a path no host
    # bind mount will ever start with.
    test "the root can be set, and it changes what counts as adoptable", %{conn: conn} do
      mounts = [%{type: "bind", source: "/home/austin/.homelab/plex/config", target: "/config"}]

      refute AdoptionPolicy.service_in_scope?("plex", mounts),
             "the default root should not match a real host path"

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "import"})

      view
      |> form("#adoption-root-form", adoption: %{"root" => "/home/austin/.homelab"})
      |> render_submit()

      assert AdoptionPolicy.adoption_root() == "/home/austin/.homelab"
      assert AdoptionPolicy.service_in_scope?("plex", mounts)
    end

    test "a relative root is refused rather than silently matching nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "import"})

      html =
        view
        |> form("#adoption-root-form", adoption: %{"root" => "~/.homelab"})
        |> render_submit()

      assert html =~ "absolute host path"
      assert Homelab.Settings.get_cached("adoption_root") == nil
    end
  end

  describe "OIDC configuration" do
    @discovery %{
      "issuer" => "https://aut.hair",
      "authorization_endpoint" => "https://aut.hair/authorize",
      "token_endpoint" => "https://aut.hair/token",
      "userinfo_endpoint" => "https://aut.hair/userinfo",
      "jwks_uri" => "https://aut.hair/.well-known/jwks.json"
    }

    defp serve_discovery(bypass) do
      Bypass.expect(bypass, "GET", "/.well-known/openid-configuration", fn conn ->
        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.resp(200, Jason.encode!(@discovery))
      end)
    end

    test "the panel was read-only; OIDC can now be configured from it", %{conn: conn} do
      bypass = Bypass.open()
      serve_discovery(bypass)
      issuer = "http://localhost:#{bypass.port}"

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "authentication"})

      view
      |> form("#oidc-form",
        oidc: %{"issuer" => issuer, "client_id" => "homelab", "client_secret" => "s3cret"}
      )
      |> render_submit()

      assert Homelab.Settings.get("oidc_issuer") == issuer
      assert Homelab.Settings.get("oidc_client_id") == "homelab"
      # Round-trips through encryption.
      assert Homelab.Settings.get("oidc_client_secret") == "s3cret"
    end

    # THE safety property. Saving an issuer turns OIDC enforcement on for every route; a
    # bad one locks the operator out of the page that would fix it (fail-open reaches
    # break-glass only when break-glass is armed, else it is a 503). A config that cannot
    # work must be refused, not persisted.
    test "an unreachable issuer is refused rather than saved", %{conn: conn} do
      bypass = Bypass.open()
      Bypass.down(bypass)
      issuer = "http://localhost:#{bypass.port}"

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "authentication"})

      html =
        view
        |> form("#oidc-form", oidc: %{"issuer" => issuer, "client_id" => "homelab"})
        |> render_submit()

      assert html =~ "Could not reach"
      assert Homelab.Settings.get("oidc_issuer") in [nil, ""]
      assert Homelab.Settings.get("oidc_client_id") in [nil, ""]
    end

    test "a blank secret keeps the stored one instead of wiping it", %{conn: conn} do
      bypass = Bypass.open()
      serve_discovery(bypass)
      issuer = "http://localhost:#{bypass.port}"

      Homelab.Settings.set("oidc_client_secret", "original", category: "auth", encrypt: true)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "authentication"})

      view
      |> form("#oidc-form",
        oidc: %{"issuer" => issuer, "client_id" => "homelab", "client_secret" => ""}
      )
      |> render_submit()

      assert Homelab.Settings.get("oidc_client_secret") == "original"
    end

    # OIDC compares redirect URIs byte-for-byte, so the operator must register the exact
    # string the AuthController sends -- not a guess at what it might be.
    test "the panel shows the callback URL the app will actually send", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "authentication"})

      assert html =~ "/auth/oidc/callback"
      assert html =~ HomelabWeb.Endpoint.url()
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

  describe "infrastructure: swarm cluster panel" do
    setup do
      # The LiveView runs in its own process, so the process-scoped :docker_client
      # override does not reach it — route the mock through app env instead, the way
      # the import tests above do.
      prev = Application.get_env(:homelab, :docker_client)
      Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
      on_exit(fn -> restore_docker_client(prev) end)
      :ok
    end

    defp select_swarm_orchestrator do
      stub(Homelab.Mocks.Orchestrator, :driver_id, fn -> "docker_swarm" end)
    end

    defp swarm_spec do
      %{
        "Name" => "default",
        "Labels" => %{},
        "Orchestration" => %{"TaskHistoryRetentionLimit" => 5},
        "Raft" => %{
          "ElectionTick" => 10,
          "HeartbeatTick" => 1,
          "SnapshotInterval" => 10_000,
          "LogEntriesForSlowFollowers" => 500
        },
        "Dispatcher" => %{"HeartbeatPeriod" => 5_000_000_000},
        "CAConfig" => %{"NodeCertExpiry" => 7_776_000_000_000_000},
        "EncryptionConfig" => %{"AutoLockManagers" => false},
        "TaskDefaults" => %{}
      }
    end

    defp active_swarm_info do
      %{
        "ServerVersion" => "26.1.4",
        "Swarm" => %{
          "LocalNodeState" => "active",
          "ControlAvailable" => true,
          "NodeID" => "node-1",
          "Nodes" => 3,
          "Managers" => 1
        }
      }
    end

    defp stub_active_swarm do
      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _ ->
          {:ok, active_swarm_info()}

        "/swarm", _ ->
          {:ok,
           %{
             "ID" => "swarm-abc",
             "CreatedAt" => "2024-03-01T10:00:00.000000000Z",
             "UpdatedAt" => "2024-06-01T12:30:00.000000000Z",
             "Version" => %{"Index" => 42},
             "Spec" => swarm_spec()
           }}

        "/version", _ ->
          {:ok, %{"Version" => "26.1.4"}}

        _, _ ->
          {:error, {:not_found, %{}}}
      end)
    end

    test "renders cluster facts, editable levers and their explanations", %{conn: conn} do
      select_swarm_orchestrator()
      stub_active_swarm()

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "Swarm cluster"
      # Read-only cluster facts.
      assert html =~ "Nodes"
      assert html =~ "Managers"
      assert html =~ "swarm-abc"
      assert html =~ "26.1.4"

      # Editable levers, in human units rather than the API's nanoseconds.
      assert html =~ "Task history retention limit"
      assert html =~ "Agent heartbeat period"
      assert html =~ "Node certificate expiry"
      assert has_element?(view, "input[name='swarm[dispatcher_heartbeat_seconds]'][value='5']")
      assert has_element?(view, "input[name='swarm[node_cert_expiry_days]'][value='90']")

      # A bare label is a failure — every lever must say what it does.
      assert html =~ "docker service ps"
      assert html =~ "Docker&#39;s default: 5"
    end

    test "shows the dangerous levers read-only, with the reason they are not editable",
         %{conn: conn} do
      select_swarm_orchestrator()
      stub_active_swarm()

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "Not editable here"
      assert html =~ "Auto-lock managers"
      assert html =~ "unrecoverable"
      assert html =~ "Raft election tick"

      # The danger is explained, not offered: no input exists for either of them.
      refute has_element?(view, "input[name='swarm[auto_lock_managers]']")
      refute has_element?(view, "input[name='swarm[election_tick]']")
    end

    test "saving valid values posts the full merged spec back to the daemon", %{conn: conn} do
      select_swarm_orchestrator()
      stub_active_swarm()

      test_pid = self()

      stub(Homelab.Mocks.DockerClient, :post, fn path, body, _ ->
        send(test_pid, {:swarm_update, path, body})
        {:ok, %{}}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "infrastructure"})

      html =
        view
        |> form("#swarm-settings-form", %{
          "swarm" => %{
            "task_history_retention_limit" => "25",
            "dispatcher_heartbeat_seconds" => "10",
            "node_cert_expiry_days" => "30"
          }
        })
        |> render_submit()

      assert html =~ "Swarm cluster settings saved"

      assert_received {:swarm_update, path, body}
      assert path =~ "version=42"
      assert get_in(body, ["Orchestration", "TaskHistoryRetentionLimit"]) == 25
      assert get_in(body, ["Dispatcher", "HeartbeatPeriod"]) == 10_000_000_000
      # The fields we never touch are still in the posted spec.
      assert get_in(body, ["Raft", "ElectionTick"]) == 10
      assert Map.has_key?(body, "EncryptionConfig")
    end

    test "an out-of-range value shows a field error and writes nothing", %{conn: conn} do
      select_swarm_orchestrator()
      stub_active_swarm()

      stub(Homelab.Mocks.DockerClient, :post, fn _, _, _ ->
        flunk("a rejected value must never reach the daemon")
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      render_click(view, "switch_section", %{"section" => "infrastructure"})

      html =
        view
        |> form("#swarm-settings-form", %{
          "swarm" => %{
            "task_history_retention_limit" => "999999",
            "dispatcher_heartbeat_seconds" => "10",
            "node_cert_expiry_days" => "30"
          }
        })
        |> render_submit()

      assert html =~ "must be between 0 and 1000"
      assert html =~ "Nothing was changed"
    end

    test "explains itself instead of crashing when the node is not in a swarm", %{conn: conn} do
      select_swarm_orchestrator()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _ ->
          {:ok, %{"Swarm" => %{"LocalNodeState" => "inactive", "ControlAvailable" => false}}}

        "/version", _ ->
          {:ok, %{"Version" => "26.1.4"}}

        _, _ ->
          {:error, {:not_found, %{}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "This node is not in a swarm"
      assert html =~ "docker swarm init"
      refute has_element?(view, "#swarm-settings-form")
    end

    test "says the node is a worker when it cannot read the cluster spec", %{conn: conn} do
      select_swarm_orchestrator()

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _ ->
          {:ok, %{"Swarm" => %{"LocalNodeState" => "active", "ControlAvailable" => false}}}

        "/version", _ ->
          {:ok, %{"Version" => "26.1.4"}}

        _, _ ->
          {:error, {:not_found, %{}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "This node is a worker"
      refute has_element?(view, "#swarm-settings-form")
    end
  end

  describe "infrastructure: docker engine panel" do
    setup do
      prev = Application.get_env(:homelab, :docker_client)
      Application.put_env(:homelab, :docker_client, Homelab.Mocks.DockerClient)
      on_exit(fn -> restore_docker_client(prev) end)
      :ok
    end

    test "shows read-only daemon facts and points at daemon.json for the real levers",
         %{conn: conn} do
      stub(Homelab.Mocks.Orchestrator, :driver_id, fn -> "docker_engine" end)

      stub(Homelab.Mocks.DockerClient, :get, fn
        "/info", _ ->
          {:ok,
           %{
             "ServerVersion" => "26.1.4",
             "Driver" => "overlay2",
             "CgroupDriver" => "systemd",
             "CgroupVersion" => "2",
             "LoggingDriver" => "json-file",
             "LiveRestoreEnabled" => false,
             "DockerRootDir" => "/var/lib/docker",
             "NCPU" => 8,
             "MemTotal" => 33_567_182_848,
             "Containers" => 12,
             "ContainersRunning" => 9,
             "Images" => 30,
             "OperatingSystem" => "Debian GNU/Linux 12",
             "Warnings" => ["WARNING: No swap limit support"],
             "Swarm" => %{"LocalNodeState" => "inactive"}
           }}

        "/version", _ ->
          {:ok, %{"Version" => "26.1.4"}}

        _, _ ->
          {:error, {:not_found, %{}}}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "Docker Engine daemon"
      assert html =~ "overlay2"
      assert html =~ "systemd"
      assert html =~ "31.3 GB"
      assert html =~ "Debian GNU/Linux 12"
      assert html =~ "No swap limit support"

      # Honesty: no fabricated editable settings, and it says where the real ones live.
      assert html =~ "daemon.json"
      assert html =~ "Live restore: off"
      refute has_element?(view, "#swarm-settings-form")
      refute html =~ "Swarm cluster"
    end

    test "renders an error panel rather than crashing when the daemon is unreachable",
         %{conn: conn} do
      stub(Homelab.Mocks.Orchestrator, :driver_id, fn -> "docker_engine" end)

      stub(Homelab.Mocks.DockerClient, :get, fn _, _ ->
        {:error, {:connection_error, :econnrefused}}
      end)

      {:ok, view, _html} = live(conn, ~p"/settings")
      html = render_click(view, "switch_section", %{"section" => "infrastructure"})

      assert html =~ "Could not read the daemon"
      assert html =~ "econnrefused"
    end
  end

  defp restore_docker_client(nil), do: Application.delete_env(:homelab, :docker_client)
  defp restore_docker_client(val), do: Application.put_env(:homelab, :docker_client, val)
end
