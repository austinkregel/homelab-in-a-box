defmodule HomelabWeb.TopologyTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias HomelabWeb.Topology

  describe "topology/1" do
    test "renders with nodes" do
      nodes = [
        %{id: "traefik", label: "Traefik", type: :gateway, status: :running, icon: "hero-shield-check"},
        %{id: "app1", label: "My App", type: :service, status: :running, icon: "hero-cube"},
        %{id: "db1", label: "PostgreSQL", type: :infra, status: :running, icon: "hero-circle-stack"}
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
