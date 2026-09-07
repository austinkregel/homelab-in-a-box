defmodule Homelab.Deployments.SettingsFormTest do
  @moduledoc """
  The Settings editor's whole contract: a deployment read into the form and written
  straight back out must describe the same deployment.

  This is the test the three forms it replaced could not have. Each of them wrote its
  own subset of the attrs, so "did opening the editor change anything?" was three
  separate questions and the answer to one of them was no — merely opening Settings and
  saving used to unpublish a git server's SSH port and repoint the proxy at port 80.
  """
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments.Findings
  alias Homelab.Deployments.SettingsForm

  defp deployment(attrs, template_attrs \\ %{}) do
    template = build(:app_template, template_attrs)

    :deployment
    |> build(Map.put(attrs, :app_template, template))
    |> Map.put(:id, 1)
  end

  describe "reading a deployment" do
    test "a proxied deployment reads its routed port as proxied" do
      form =
        deployment(%{
          exposure_mode_override: "public",
          domain: "git.example.com",
          routed_port: 3000,
          ports_override: [
            %{"internal" => "3000", "protocol" => "tcp", "role" => "web"},
            %{"internal" => "22", "protocol" => "tcp", "role" => "ssh", "published" => true}
          ]
        })
        |> SettingsForm.from_deployment()

      assert [%{"internal" => "3000", "exposure" => "proxy"}, %{"exposure" => "host"}] =
               form.ports

      assert form.namespace == "own"
      assert form.auth == "public"
    end

    test "host networking reads as a namespace, not as an exposure" do
      form =
        deployment(%{exposure_mode_override: "host_network"})
        |> SettingsForm.from_deployment()

      assert form.namespace == "host"
      assert SettingsForm.allowed_exposures(form) == ["host"]
    end

    test "a namespace child cannot publish a port" do
      form =
        deployment(%{network_parent_id: 7, exposure_mode_override: "public"})
        |> SettingsForm.from_deployment()

      assert form.namespace == "donor"
      assert form.donor_id == "7"
      assert SettingsForm.allowed_exposures(form) == ["proxy", "internal"]
    end

    test "the primary domain, extra paths and alias hosts read as one table" do
      form =
        deployment(%{
          exposure_mode_override: "public",
          domain: "app.example.com",
          routed_port: 8000,
          extra_routes: [%{"path_prefix" => "/app", "port" => 6001}],
          additional_domains: [
            %{"host" => "example.com", "path_prefix" => "/.well-known/matrix", "port" => 8000}
          ]
        })
        |> SettingsForm.from_deployment()

      assert [
               %{"host" => "app.example.com", "path_prefix" => "", "primary" => true},
               %{"host" => "app.example.com", "path_prefix" => "/app", "port" => "6001"},
               %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"}
             ] = form.routes
    end

    test "runtime fields carry the effective value, not a mode flag" do
      form =
        deployment(
          %{capabilities_add_override: ["NET_ADMIN"]},
          %{command: ["serve", "--port", "80"], capabilities_add: ["CHOWN"]}
        )
        |> SettingsForm.from_deployment()

      # The catalog's own command is what the operator sees, filled in -- one argument
      # per line, so a value with spaces in it stays one argument.
      assert form.command == "serve\n--port\n80"
      # The override wins, and it is shown as the real list rather than as "custom".
      assert form.caps_add == ["NET_ADMIN"]
    end
  end

  describe "round trip" do
    test "reading and writing back changes nothing" do
      deployment =
        deployment(%{
          exposure_mode_override: "sso_protected",
          domain: "git.example.com",
          routed_port: 3000,
          ports_override: [
            %{
              "internal" => "3000",
              "protocol" => "tcp",
              "role" => "web",
              "description" => "web UI",
              "published" => false,
              "optional" => false
            },
            %{
              "internal" => "22",
              "external" => "2222",
              "protocol" => "tcp",
              "role" => "ssh",
              "description" => "git over SSH",
              "published" => true,
              "optional" => false
            }
          ],
          proxy_options: %{"sticky" => false, "backend_scheme" => "http"}
        })

      attrs =
        deployment
        |> SettingsForm.from_deployment()
        |> SettingsForm.to_attrs(deployment)

      assert attrs.exposure_mode_override == "sso_protected"
      assert attrs.domain == "git.example.com"
      assert attrs.routed_port == 3000
      assert attrs.network_parent_id == nil

      assert [
               %{"internal" => "3000", "published" => false},
               %{"internal" => "22", "external" => "2222", "published" => true}
             ] = attrs.ports_override
    end

    test "an untouched healthcheck keeps inheriting the catalog's" do
      deployment = deployment(%{}, %{health_check: %{"path" => "/health", "interval" => 30}})
      form = SettingsForm.from_deployment(deployment)

      assert form.health["mode"] == "path"
      assert form.health["path"] == "/health"
      assert SettingsForm.health_override(form, deployment) == nil
    end

    test "editing the healthcheck writes an override" do
      deployment = deployment(%{}, %{health_check: %{"path" => "/health"}})

      form =
        deployment
        |> SettingsForm.from_deployment()
        |> then(&%{&1 | health: Map.put(&1.health, "path", "/healthz")})

      assert %{"path" => "/healthz"} = SettingsForm.health_override(form, deployment)
    end

    test "a runtime field still equal to the catalog's keeps inheriting" do
      deployment = deployment(%{}, %{capabilities_add: ["NET_ADMIN"]})
      form = SettingsForm.from_deployment(deployment)

      assert SettingsForm.to_attrs(form, deployment).capabilities_add_override == nil
    end

    test "clearing a runtime field the catalog sets is an override, not an inherit" do
      deployment = deployment(%{}, %{capabilities_add: ["NET_ADMIN"]})

      form =
        deployment
        |> SettingsForm.from_deployment()
        |> then(&%{&1 | caps_add: []})

      assert SettingsForm.to_attrs(form, deployment).capabilities_add_override == []
    end
  end

  describe "derived exposure" do
    test "a route makes it a proxy mode, named by the auth" do
      form = %SettingsForm{
        auth: "sso_protected",
        routes: [%{"host" => "a.example.com", "port" => "80", "primary" => true}]
      }

      assert SettingsForm.exposure(form) == "sso_protected"
    end

    test "a published port with no route is host mode" do
      form = %SettingsForm{ports: [%{"internal" => "22", "exposure" => "host"}]}
      assert SettingsForm.exposure(form) == "host"
    end

    test "nothing published and nothing routed is internal" do
      form = %SettingsForm{ports: [%{"internal" => "5432", "exposure" => "internal"}]}
      assert SettingsForm.exposure(form) == "service"
    end

    test "the host namespace wins over everything below it" do
      form = %SettingsForm{
        namespace: "host",
        ports: [%{"internal" => "80", "exposure" => "host"}]
      }

      assert SettingsForm.exposure(form) == "host_network"
    end
  end

  describe "normalize/1" do
    test "a namespace that forbids an exposure takes it off the port" do
      form =
        %SettingsForm{
          namespace: "donor",
          ports: [%{"internal" => "8080", "exposure" => "host"}]
        }
        |> SettingsForm.normalize()

      assert [%{"exposure" => "proxy"}] = form.ports
    end

    test "the host namespace clears the routes it cannot serve" do
      form =
        %SettingsForm{
          namespace: "host",
          routes: [%{"host" => "a.example.com", "port" => "80", "primary" => true}]
        }
        |> SettingsForm.normalize()

      assert form.routes == []
    end

    test "removing the first route promotes the next" do
      form =
        %SettingsForm{
          routes: [
            %{"host" => "b.example.com", "port" => "80", "primary" => false},
            %{"host" => "c.example.com", "port" => "80", "primary" => false}
          ]
        }
        |> SettingsForm.normalize()

      assert [%{"host" => "b.example.com", "primary" => true}, %{"primary" => false}] =
               form.routes
    end
  end

  describe "health_test/1" do
    test "a path check emits the same probe the spec builder builds" do
      form = %SettingsForm{
        backend_scheme: "http",
        health: %{"mode" => "path", "path" => "/up"},
        routes: [%{"host" => "a.example.com", "port" => "4000", "primary" => true}]
      }

      assert ["CMD-SHELL", probe] = SettingsForm.health_test(form)
      assert probe =~ "http://localhost:4000/up"
    end

    test "an exec check emits a CMD array with no shell" do
      form = %SettingsForm{
        health: %{"mode" => "command", "shell" => false, "args" => ["/bin/check", "-q", ""]}
      }

      assert SettingsForm.health_test(form) == ["CMD", "/bin/check", "-q"]
    end

    test "a blank check declares nothing" do
      form = %SettingsForm{health: %{"mode" => "command", "shell" => true, "command" => ""}}
      refute SettingsForm.declares_health?(form)
    end
  end

  describe "diff/2" do
    test "reports the derived exposure the page never asked for directly" do
      base = %SettingsForm{ports: [%{"internal" => "80", "exposure" => "internal"}]}
      edited = %SettingsForm{ports: [%{"internal" => "80", "exposure" => "host"}]}

      labels = base |> SettingsForm.diff(edited) |> Enum.map(& &1.label)

      assert "exposure_mode (derived)" in labels
      assert "Ports" in labels
    end

    test "an unchanged form has nothing to review" do
      form = %SettingsForm{}
      assert SettingsForm.diff(form, form) == []
    end
  end

  describe "findings" do
    test "a UDP port set to proxied breaks at runtime, it does not merely warn" do
      form = %SettingsForm{
        ports: [%{"internal" => "1900", "protocol" => "udp", "exposure" => "proxy"}]
      }

      assert %{severity: :broken} =
               Enum.find(Findings.for_form(form), &(&1.key == "UDP cannot be proxied"))
    end

    test "replicas above one in a shared namespace is a refusal" do
      form = %SettingsForm{namespace: "donor", replicas: "3"}

      assert %{severity: :refuse} =
               Enum.find(
                 Findings.for_form(form),
                 &(&1.key == "Replicas cannot share a namespace")
               )
    end

    test "a guarded host binding is dropped, not refused" do
      form = %SettingsForm{
        auth: "sso_protected",
        ports: [%{"internal" => "3000", "protocol" => "tcp", "exposure" => "host"}],
        routes: [%{"host" => "a.example.com", "port" => "3000", "primary" => true}]
      }

      assert %{severity: :drop} =
               Enum.find(Findings.for_form(form), &(&1.key == "Binding dropped"))
    end

    test "two ports competing for one host binding is caught before the daemon sees it" do
      form = %SettingsForm{
        ports: [
          %{"internal" => "3000", "protocol" => "tcp", "exposure" => "host", "external" => "80"},
          %{"internal" => "4000", "protocol" => "tcp", "exposure" => "host", "external" => "80"}
        ]
      }

      assert %{severity: :broken} =
               Enum.find(Findings.for_form(form), &(&1.key == "Two ports, one host binding"))
    end

    test "a path probe with no declared port falls back to :80 and never turns healthy" do
      form = %SettingsForm{health: %{"mode" => "path", "path" => "/up"}, ports: []}

      assert %{severity: :broken} =
               Enum.find(Findings.for_form(form), &(&1.key == "Health check probes :80"))
    end
  end
end
