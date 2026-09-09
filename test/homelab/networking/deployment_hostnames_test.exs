defmodule Homelab.Networking.DeploymentHostnamesTest do
  @moduledoc """
  Which names a deployment needs DNS records for.

  `PublishDns` reads this list both to write records and to scope its rollback to exactly
  the ones it wrote, so a name missing here is a name that never resolves and never gets
  cleaned up either.
  """
  use ExUnit.Case, async: true

  alias Homelab.Deployments.Deployment
  alias Homelab.Networking

  test "the primary domain leads the list" do
    deployment = %Deployment{domain: "app.example.com", additional_domains: [], tcp_routes: []}

    assert Networking.deployment_hostnames(deployment) == ["app.example.com"]
  end

  test "additional domains and TCP route hosts are all included" do
    deployment = %Deployment{
      domain: "app.example.com",
      additional_domains: [%{"host" => "www.example.com"}],
      tcp_routes: [%{"host" => "db.example.com", "port" => 5432}]
    }

    hostnames = Networking.deployment_hostnames(deployment)

    assert "app.example.com" in hostnames
    assert "www.example.com" in hostnames
    assert "db.example.com" in hostnames
  end

  # A datastore reachable only over TCP has no `domain` at all, so this list is not
  # always led by one. Its host still has to resolve, and a missing record surfaces as a
  # connection timeout in an application's logs with nothing pointing at DNS.
  test "a TCP-only deployment still needs its host to resolve" do
    deployment = %Deployment{
      domain: nil,
      additional_domains: [],
      tcp_routes: [%{"host" => "postgres-media.example.com", "port" => 5432}]
    }

    assert Networking.deployment_hostnames(deployment) == ["postgres-media.example.com"]
  end

  test "a host serving both HTTP and TCP is listed once" do
    deployment = %Deployment{
      domain: "app.example.com",
      additional_domains: [],
      tcp_routes: [%{"host" => "app.example.com", "port" => 5432}]
    }

    assert Networking.deployment_hostnames(deployment) == ["app.example.com"]
  end
end
