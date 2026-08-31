defmodule Homelab.Deployments.HostnameLookupTest do
  @moduledoc """
  `get_deployment_by_hostname/1` answers a request that arrived on a name nothing else
  would take: which deployment was supposed to be there? Its input is a Host header, so
  it is fed whatever a client cares to send.
  """
  use Homelab.DataCase, async: true

  import Homelab.Factory

  alias Homelab.Deployments

  test "finds a deployment by its primary domain" do
    deployment = insert(:deployment, domain: "matrix.example.com")

    assert %{id: id} = Deployments.get_deployment_by_hostname("matrix.example.com")
    assert id == deployment.id
  end

  # Every `additional_domains` entry becomes a Traefik router of its own
  # (SpecBuilder.additional_domain_labels/2), so every one of them goes dark when the
  # container does and has to resolve back to the deployment that owns it.
  test "finds a deployment by a host alias" do
    deployment =
      insert(:deployment,
        domain: "matrix.example.com",
        additional_domains: [
          %{"host" => "example.com", "path_prefix" => "/.well-known/matrix"},
          %{"host" => "chat.example.com"}
        ]
      )

    assert %{id: id} = Deployments.get_deployment_by_hostname("chat.example.com")
    assert id == deployment.id
    assert %{id: ^id} = Deployments.get_deployment_by_hostname("example.com")
  end

  # A Host header is not a stored value: it arrives capitalised, with the port the
  # browser connected on, or with the root label a resolver-savvy client appends.
  test "normalizes the host the way a Host header actually arrives" do
    deployment = insert(:deployment, domain: "matrix.example.com")

    for host <- ["MATRIX.Example.COM", "matrix.example.com.", "matrix.example.com:8443"] do
      assert %{id: id} = Deployments.get_deployment_by_hostname(host), "no match for #{host}"
      assert id == deployment.id
    end
  end

  test "returns nil for a name nothing is routed at" do
    insert(:deployment, domain: "matrix.example.com")

    assert Deployments.get_deployment_by_hostname("nothing.example.com") == nil
    assert Deployments.get_deployment_by_hostname("") == nil
    assert Deployments.get_deployment_by_hostname(nil) == nil
  end

  # The alias scan prefilters in SQL with a LIKE over the JSON, so a host that is not a
  # hostname must not reach it carrying wildcards of its own — and a `%` matching every
  # row would hand back an arbitrary deployment for a host nobody routes.
  test "a host header carrying LIKE wildcards matches nothing" do
    insert(:deployment,
      domain: "matrix.example.com",
      additional_domains: [%{"host" => "chat.example.com"}]
    )

    assert Deployments.get_deployment_by_hostname("%") == nil
    assert Deployments.get_deployment_by_hostname("%.example.com") == nil
    assert Deployments.get_deployment_by_hostname("chat_example.com") == nil
  end

  # A row with aliases and no primary domain was never routed at all — SpecBuilder emits
  # no router without `domain` — so it cannot be what a held request was looking for.
  test "ignores a deployment that holds aliases but no domain of its own" do
    insert(:deployment, domain: nil, additional_domains: [%{"host" => "chat.example.com"}])

    assert Deployments.get_deployment_by_hostname("chat.example.com") == nil
  end

  test "preloads what the caller renders from" do
    insert(:deployment, domain: "matrix.example.com")

    deployment = Deployments.get_deployment_by_hostname("matrix.example.com")

    assert %Homelab.Tenants.Tenant{} = deployment.tenant
    assert %Homelab.Catalog.AppTemplate{} = deployment.app_template
  end
end
