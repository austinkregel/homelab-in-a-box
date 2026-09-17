defmodule HomelabWeb.TopologyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HomelabWeb.Topology

  # A node's TYPE comes from its image and its port roles, and both have overrides that
  # the Ports tab and a version bump write. Reading the template drew the topology of a
  # deployment that is not running.
  describe "from_tenant/1 reads what the deployment actually runs" do
    defp deployment(overrides) do
      Map.merge(
        %Homelab.Deployments.Deployment{
          id: 1,
          status: :running,
          domain: nil,
          image_override: nil,
          ports_override: nil,
          exposure_mode_override: nil,
          app_template: %Homelab.Catalog.AppTemplate{
            id: 1,
            name: "Thing",
            slug: "thing",
            image: "nginx:1.27",
            ports: [%{"internal" => 80, "role" => "web"}],
            exposure_mode: :public
          }
        },
        overrides
      )
    end

    test "an image override decides the node type, not the template image" do
      %{nodes: [node | _]} = Topology.from_tenant([deployment(%{image_override: "postgres:17"})])

      assert node.subtitle == "postgres:17"
      assert node.type == Topology.classify_image("postgres:17")
    end

    test "a ports override decides the database promotion and the web badge" do
      %{nodes: [node | _]} =
        Topology.from_tenant([
          deployment(%{ports_override: [%{"internal" => 5432, "role" => "database"}]})
        ])

      assert node.type == :database
      refute node.badge == "Web"
    end

    test "an exposure override is what the node reports" do
      %{nodes: [node | _]} =
        Topology.from_tenant([deployment(%{exposure_mode_override: "service"})])

      exposure = Enum.find(node.properties, &(&1.key == "exposure"))
      assert exposure.value == "Service"
    end
  end

  describe "topology/1" do
    test "renders with nodes" do
      nodes = [
        %{
          id: "traefik",
          label: "Traefik",
          type: :gateway,
          status: :running,
          icon: "hero-shield-check"
        },
        %{id: "app1", label: "My App", type: :service, status: :running, icon: "hero-cube"},
        %{
          id: "db1",
          label: "PostgreSQL",
          type: :infra,
          status: :running,
          icon: "hero-circle-stack"
        }
      ]

      html = render_component(&Topology.topology/1, nodes: nodes, edges: [])
      assert html =~ "Gateway"
      assert html =~ "Services"
      assert html =~ "Infrastructure"
    end

    test "renders with empty nodes" do
      html = render_component(&Topology.topology/1, nodes: [], edges: [])
      assert html =~ "Gateway"
    end

    test "renders with highlight" do
      nodes = [
        %{id: "app1", label: "Test", type: :service, status: :running, icon: "hero-cube"}
      ]

      html = render_component(&Topology.topology/1, nodes: nodes, edges: [], highlight: "app1")
      assert is_binary(html)
    end
  end
end
